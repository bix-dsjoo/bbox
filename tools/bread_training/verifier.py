"""Conditional embedding verifier evaluation and deterministic adoption gates."""

from __future__ import annotations

import argparse
import json
import math
import statistics
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Protocol, Sequence
from urllib.parse import urlparse

from tools.bread_training.metrics import (
    ClassificationPrediction,
    apply_label_policy,
    calibrate_auto_label,
    classification_precision,
)


class CandidateUnavailable(RuntimeError):
    pass


@dataclass(frozen=True)
class VerifierMetrics:
    kind: str
    ambiguous_accuracy_gain: float
    review_reduction_at_98_precision: float
    auto_precision_drop: float
    p50_ms: float
    p95_ms: float
    supported_class_precision: Mapping[int, float]


@dataclass(frozen=True)
class VerifierDecision:
    kind: str
    metrics: VerifierMetrics


@dataclass(frozen=True)
class VerifierSample:
    sample_id: str
    true_class: int
    classifier_class: int
    classifier_ambiguous: bool
    payload: Any
    prototype_group: int | None = None


@dataclass(frozen=True)
class VerifierPrediction:
    sample_id: str
    predicted_class: int
    score: float
    margin: float
    latency_ms: float


class VerifierCandidate(Protocol):
    kind: str

    def predict(
        self, samples: Sequence[VerifierSample]
    ) -> Sequence[VerifierPrediction]: ...


def cached_default_weight_path(url: str, hub_directory: Path) -> Path:
    """Return a cached TorchVision weight without invoking a downloader."""

    filename = Path(urlparse(url).path).name
    for candidate in (
        hub_directory / filename,
        hub_directory / "checkpoints" / filename,
    ):
        if candidate.is_file():
            return candidate
    raise CandidateUnavailable(
        f"TorchVision default weight {filename!r} is not cached; network download is disabled"
    )


def _normalize(vector: Sequence[float]) -> tuple[float, ...]:
    values = tuple(float(value) for value in vector)
    magnitude = math.sqrt(sum(value * value for value in values))
    if not values or not math.isfinite(magnitude) or magnitude <= 0.0:
        raise ValueError("embedding vectors must have finite non-zero magnitude")
    return tuple(value / magnitude for value in values)


class PrototypeVerifier:
    def __init__(self, kind: str, embed_many: Any):
        self.kind = kind
        self._embed_many = embed_many
        self._prototypes: dict[int, tuple[float, ...]] = {}
        self._group_prototypes: dict[int, dict[int, tuple[float, ...]]] = {}

    def _build_prototypes(
        self, sources_by_class: Mapping[int, Sequence[Any]]
    ) -> dict[int, tuple[float, ...]]:
        prototypes: dict[int, tuple[float, ...]] = {}
        for class_id in sorted(sources_by_class):
            payloads = tuple(sources_by_class[class_id])
            if not payloads:
                continue
            vectors = tuple(_normalize(item) for item in self._embed_many(payloads))
            if len(vectors) != len(payloads):
                raise ValueError("embedder returned the wrong prototype vector count")
            dimensions = {len(vector) for vector in vectors}
            if len(dimensions) != 1:
                raise ValueError("prototype vectors have inconsistent dimensions")
            averaged = tuple(
                statistics.fmean(vector[index] for vector in vectors)
                for index in range(len(vectors[0]))
            )
            prototypes[int(class_id)] = _normalize(averaged)
        if not prototypes:
            raise ValueError("at least one class prototype is required")
        return prototypes

    def fit(self, sources_by_class: Mapping[int, Sequence[Any]]) -> None:
        prototypes = self._build_prototypes(sources_by_class)
        self._prototypes = prototypes

    def fit_group(
        self, group: int, sources_by_class: Mapping[int, Sequence[Any]]
    ) -> None:
        self._group_prototypes[int(group)] = self._build_prototypes(sources_by_class)

    def predict(
        self, samples: Sequence[VerifierSample]
    ) -> tuple[VerifierPrediction, ...]:
        if not self._prototypes and not self._group_prototypes:
            raise RuntimeError("verifier prototypes must be fitted before prediction")
        predictions: list[VerifierPrediction] = []
        for sample in samples:
            started = time.perf_counter()
            embedded = tuple(self._embed_many((sample.payload,)))
            if len(embedded) != 1:
                raise ValueError("embedder returned the wrong query vector count")
            vector = _normalize(embedded[0])
            prototypes = (
                self._group_prototypes.get(sample.prototype_group, {})
                if sample.prototype_group is not None
                else self._prototypes
            )
            if not prototypes:
                raise RuntimeError(
                    f"no prototypes fitted for group {sample.prototype_group}"
                )
            scored = sorted(
                (
                    sum(a * b for a, b in zip(vector, prototype)),
                    class_id,
                )
                for class_id, prototype in prototypes.items()
            )
            best_score, best_class = scored[-1]
            second_score = scored[-2][0] if len(scored) > 1 else 0.0
            predictions.append(
                VerifierPrediction(
                    sample_id=sample.sample_id,
                    predicted_class=best_class,
                    score=max(0.0, min(1.0, best_score)),
                    margin=max(0.0, min(1.0, best_score - second_score)),
                    latency_ms=(time.perf_counter() - started) * 1000,
                )
            )
        return tuple(predictions)


class FoldVerifierCandidate:
    def __init__(self, kind: str, verifier_factory: Any):
        self.kind = kind
        self._verifier_factory = verifier_factory
        self._verifiers: dict[int, Any] = {}

    def fit_group(
        self, group: int, sources_by_class: Mapping[int, Sequence[Any]]
    ) -> None:
        verifier = self._verifier_factory(int(group))
        verifier.fit_group(int(group), sources_by_class)
        self._verifiers[int(group)] = verifier

    def predict(
        self, samples: Sequence[VerifierSample]
    ) -> tuple[VerifierPrediction, ...]:
        predictions: list[VerifierPrediction] = []
        for sample in samples:
            if sample.prototype_group is None:
                raise ValueError("fold verifier samples require a prototype group")
            verifier = self._verifiers.get(sample.prototype_group)
            if verifier is None:
                raise RuntimeError(
                    f"no verifier fitted for fold {sample.prototype_group}"
                )
            predictions.extend(verifier.predict((sample,)))
        return tuple(predictions)


def _payload_image(payload: Any) -> Any:
    try:
        import cv2
        import numpy as np
    except (ImportError, OSError) as error:
        raise CandidateUnavailable("OpenCV and NumPy are required for verifier crops") from error
    if isinstance(payload, np.ndarray):
        return payload
    if isinstance(payload, Mapping):
        image_path = Path(str(payload["image_path"]))
        bbox = payload.get("bbox")
    else:
        image_path = Path(payload)
        bbox = None
    image = cv2.imdecode(np.fromfile(str(image_path), dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError(f"Could not decode verifier image: {image_path}")
    if bbox is None:
        return image
    x, y, width, height = (float(value) for value in bbox)
    left = max(0, math.floor(x))
    top = max(0, math.floor(y))
    right = min(image.shape[1], math.ceil(x + width))
    bottom = min(image.shape[0], math.ceil(y + height))
    if right <= left or bottom <= top:
        raise ValueError(f"Verifier crop is empty for image: {image_path}")
    return image[top:bottom, left:right]


class YoloPenultimateVerifier(PrototypeVerifier):
    def __init__(self, classifier_weights: Path):
        self.classifier_weights = classifier_weights
        self._model: Any = None
        self._captured: list[tuple[float, ...]] = []
        super().__init__("yolo_penultimate", self._embed_yolo)

    def _load(self) -> None:
        if self._model is not None:
            return
        try:
            from ultralytics import YOLO
        except (ImportError, OSError) as error:
            raise CandidateUnavailable(
                "Could not load the optional Ultralytics verifier runtime: " + str(error)
            ) from error
        if not self.classifier_weights.is_file():
            raise CandidateUnavailable(
                f"Classifier verifier weight does not exist: {self.classifier_weights}"
            )
        self._model = YOLO(str(self.classifier_weights))
        try:
            pooling = self._model.model.model[-1].pool
        except (AttributeError, IndexError, TypeError) as error:
            raise CandidateUnavailable(
                "Classifier does not expose a penultimate pooling layer"
            ) from error

        def capture(_module: Any, _inputs: Any, output: Any) -> None:
            flattened = output.detach().cpu().flatten(1).tolist()
            self._captured.extend(tuple(float(value) for value in row) for row in flattened)

        pooling.register_forward_hook(capture)

    def _embed_yolo(self, payloads: Sequence[Any]) -> tuple[tuple[float, ...], ...]:
        self._load()
        images = [_payload_image(payload) for payload in payloads]
        self._captured = []
        self._model.predict(
            source=images,
            imgsz=224,
            device="cpu",
            verbose=False,
            stream=False,
        )
        if len(self._captured) != len(images):
            raise RuntimeError("YOLO pooling hook returned the wrong embedding count")
        return tuple(self._captured)


class MobileNetV3SmallVerifier(PrototypeVerifier):
    DEFAULT_WEIGHT_URL = (
        "https://download.pytorch.org/models/mobilenet_v3_small-047dcff4.pth"
    )

    def __init__(self, hub_directory: Path | None = None):
        self.hub_directory = hub_directory
        self._torch: Any = None
        self._model: Any = None
        self._transform: Any = None
        super().__init__("mobilenet_v3_small", self._embed_mobilenet)

    def _load(self) -> None:
        if self._model is not None:
            return
        if self.hub_directory is not None:
            cached_default_weight_path(self.DEFAULT_WEIGHT_URL, self.hub_directory)
        try:
            import torch
            from torchvision.models import (
                MobileNet_V3_Small_Weights,
                mobilenet_v3_small,
            )
        except (ImportError, OSError) as error:
            raise CandidateUnavailable(
                "Could not load the optional TorchVision verifier runtime: " + str(error)
            ) from error
        hub_directory = (
            self.hub_directory if self.hub_directory is not None else Path(torch.hub.get_dir())
        )
        cached_default_weight_path(self.DEFAULT_WEIGHT_URL, hub_directory)
        weights = MobileNet_V3_Small_Weights.DEFAULT
        model = mobilenet_v3_small(weights=weights)
        model.classifier = torch.nn.Identity()
        model.eval()
        self._torch = torch
        self._model = model
        self._transform = weights.transforms()

    def _embed_mobilenet(
        self, payloads: Sequence[Any]
    ) -> tuple[tuple[float, ...], ...]:
        self._load()
        try:
            from PIL import Image
        except ImportError as error:
            raise CandidateUnavailable("Pillow is required for MobileNet verifier") from error
        tensors = []
        for payload in payloads:
            image = _payload_image(payload)
            rgb = image[:, :, ::-1]
            tensors.append(self._transform(Image.fromarray(rgb)))
        with self._torch.inference_mode():
            output = self._model(self._torch.stack(tensors)).detach().cpu().tolist()
        return tuple(tuple(float(value) for value in row) for row in output)


def verifier_gate(metrics: VerifierMetrics) -> bool:
    benefit = (
        metrics.ambiguous_accuracy_gain >= 0.03
        or metrics.review_reduction_at_98_precision >= 0.15
    )
    safe = (
        metrics.auto_precision_drop <= 0.005
        and metrics.p50_ms <= 1000
        and metrics.p95_ms <= 2000
    )
    supported = bool(metrics.supported_class_precision) and all(
        value >= 0.95 for value in metrics.supported_class_precision.values()
    )
    return benefit and safe and supported


def choose_verifier(
    metrics_by_kind: Mapping[str, VerifierMetrics]
) -> VerifierDecision:
    if "none" not in metrics_by_kind:
        raise ValueError("classifier-only metrics with kind 'none' are required")
    passing = [
        metrics
        for kind, metrics in metrics_by_kind.items()
        if kind != "none" and verifier_gate(metrics)
    ]
    if not passing:
        return VerifierDecision(kind="none", metrics=metrics_by_kind["none"])
    selected = max(
        passing,
        key=lambda item: (
            item.review_reduction_at_98_precision,
            item.ambiguous_accuracy_gain,
            -item.p50_ms,
            item.kind,
        ),
    )
    return VerifierDecision(kind=selected.kind, metrics=selected)


def _percentile(values: Sequence[float], percentile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    position = (len(ordered) - 1) * percentile
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = position - lower
    return ordered[lower] * (1.0 - fraction) + ordered[upper] * fraction


def _classifier_only_metrics() -> VerifierMetrics:
    return VerifierMetrics(
        kind="none",
        ambiguous_accuracy_gain=0.0,
        review_reduction_at_98_precision=0.0,
        auto_precision_drop=0.0,
        p50_ms=0.0,
        p95_ms=0.0,
        supported_class_precision={},
    )


def _evaluate_candidate(
    samples: Sequence[VerifierSample], candidate: VerifierCandidate
) -> VerifierMetrics:
    baseline_accuracy = (
        statistics.fmean(
            sample.classifier_class == sample.true_class for sample in samples
        )
        if samples
        else 0.0
    )
    predictions = tuple(candidate.predict(samples)) if samples else ()
    if len(predictions) != len(samples):
        raise ValueError(f"{candidate.kind} returned the wrong prediction count")
    expected_ids = tuple(sample.sample_id for sample in samples)
    actual_ids = tuple(prediction.sample_id for prediction in predictions)
    if actual_ids != expected_ids:
        raise ValueError(f"{candidate.kind} changed verifier sample ordering")
    correct = tuple(
        prediction.predicted_class == sample.true_class
        for sample, prediction in zip(samples, predictions)
    )
    candidate_accuracy = statistics.fmean(correct) if correct else 0.0
    policy_predictions = tuple(
        ClassificationPrediction(
            sample_id=prediction.sample_id,
            true_class=sample.true_class,
            predicted_class=prediction.predicted_class,
            confidence=prediction.score,
            margin=prediction.margin,
            top3=(prediction.predicted_class,),
        )
        for sample, prediction in zip(samples, predictions)
    )
    policy = calibrate_auto_label(policy_predictions, min_precision=0.98)
    accepted = apply_label_policy(policy_predictions, policy)
    accepted_ids = {item.sample_id for item in accepted}
    true_support = {
        class_id: sum(sample.true_class == class_id for sample in samples)
        for class_id in {sample.true_class for sample in samples}
    }
    precisions: dict[int, float] = {}
    for class_id in sorted(
        class_id for class_id, support in true_support.items() if support >= 20
    ):
        class_results = tuple(
            is_correct
            for prediction, is_correct in zip(policy_predictions, correct)
            if prediction.sample_id in accepted_ids
            and prediction.predicted_class == class_id
        )
        if class_results:
            precisions[class_id] = statistics.fmean(class_results)
    auto_precision = classification_precision(accepted) if accepted else 1.0
    latencies = tuple(prediction.latency_ms for prediction in predictions)
    return VerifierMetrics(
        kind=candidate.kind,
        ambiguous_accuracy_gain=candidate_accuracy - baseline_accuracy,
        review_reduction_at_98_precision=(
            len(accepted) / len(samples) if samples else 0.0
        ),
        auto_precision_drop=max(0.0, 0.98 - auto_precision),
        p50_ms=_percentile(latencies, 0.50),
        p95_ms=_percentile(latencies, 0.95),
        supported_class_precision=precisions,
    )


def evaluate_verifiers(
    ambiguous_samples: Iterable[VerifierSample],
    candidates: Iterable[VerifierCandidate],
) -> VerifierDecision:
    """Evaluate candidates after filtering out classifier-confident samples."""

    samples = tuple(
        sample for sample in ambiguous_samples if sample.classifier_ambiguous
    )
    metrics_by_kind: dict[str, VerifierMetrics] = {
        "none": _classifier_only_metrics()
    }
    for candidate in candidates:
        metrics_by_kind[candidate.kind] = _evaluate_candidate(samples, candidate)
    return choose_verifier(metrics_by_kind)


def run_verifier_bakeoff(predictions_path: Path, output_path: Path) -> Path:
    repository_root = Path(__file__).resolve().parents[2]
    allowed_output_root = (repository_root / "outputs").resolve()
    resolved_output = output_path.resolve()
    try:
        resolved_output.relative_to(allowed_output_root)
    except ValueError as error:
        raise ValueError(f"Output must be under {allowed_output_root}") from error
    records = tuple(
        json.loads(line)
        for line in predictions_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    )
    context_path = predictions_path.parent / "verifier_context.json"
    if not context_path.is_file():
        raise FileNotFoundError(f"Verifier context does not exist: {context_path}")
    context = json.loads(context_path.read_text(encoding="utf-8"))
    samples = tuple(
        VerifierSample(
            sample_id=str(record["sample_id"]),
            true_class=int(record["true_class"]),
            classifier_class=int(record["predicted_class"]),
            classifier_ambiguous=bool(record["classifier_ambiguous"]),
            payload={
                "image_path": record["image_path"],
                "bbox": record["bbox"],
            },
            prototype_group=int(record["fold"]),
        )
        for record in records
    )
    ambiguous = tuple(sample for sample in samples if sample.classifier_ambiguous)
    metrics_by_kind: dict[str, VerifierMetrics] = {
        "none": _classifier_only_metrics()
    }
    availability: dict[str, dict[str, Any]] = {}
    if "classifier_weights_by_fold" in context:
        yolo_factory = lambda: FoldVerifierCandidate(
            "yolo_penultimate",
            lambda fold: YoloPenultimateVerifier(
                Path(context["classifier_weights_by_fold"][str(fold)])
            ),
        )
    else:
        yolo_factory = lambda: YoloPenultimateVerifier(
            Path(context["classifier_weights"])
        )
    candidate_factories = (
        ("yolo_penultimate", yolo_factory),
        ("mobilenet_v3_small", MobileNetV3SmallVerifier),
    )
    for kind, factory in candidate_factories:
        try:
            candidate = factory()
            for fold_text, sources_by_class in sorted(
                context["prototype_sources"].items(), key=lambda item: int(item[0])
            ):
                candidate.fit_group(
                    int(fold_text),
                    {
                        int(class_id): tuple(paths)
                        for class_id, paths in sources_by_class.items()
                        if paths
                    },
                )
            metrics_by_kind[kind] = _evaluate_candidate(ambiguous, candidate)
            availability[kind] = {
                "available": True,
                "ambiguous_invocations": len(ambiguous),
            }
        except CandidateUnavailable as error:
            availability[kind] = {
                "available": False,
                "reason": str(error),
                "ambiguous_invocations": 0,
            }
    decision = choose_verifier(metrics_by_kind)
    resolved_output.parent.mkdir(parents=True, exist_ok=True)
    resolved_output.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "sample_count": len(samples),
                "ambiguous_sample_count": len(ambiguous),
                "conditional_only": True,
                "availability": availability,
                "candidates": {
                    kind: asdict(metrics) for kind, metrics in metrics_by_kind.items()
                },
                "decision": asdict(decision),
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    return resolved_output


def _parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--predictions", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    args = _parse_args(argv)
    output = run_verifier_bakeoff(args.predictions, args.output)
    print(f"report={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
