"""Train detector/classifier folds and run leakage-safe OOF evaluation."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import shutil
import statistics
import time
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence

from tools.bread_training.metrics import (
    BBox,
    ClassificationPrediction,
    DetectorReport,
    LabelPolicy,
    calibrate_auto_label,
    classifier_report,
    deployment_policy_report,
    detector_report,
    derive_deployment_policy,
    is_ambiguous,
    match_detections,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
AP_CONFIDENCE_FLOOR = 0.001
DEFAULT_THRESHOLD_CANDIDATES = tuple(value / 100 for value in range(5, 100, 5))
DEFAULT_CLASSIFIER_INITIAL_WEIGHTS = Path("yolov8n-cls.pt")
DETECTOR_CANDIDATE_EVALUATOR_VERSION = 2
DETECTOR_CANDIDATE_TRAINER_SCHEMA_VERSION = 2


@dataclass(frozen=True)
class DetectorTrainConfig:
    initial_weights: Path
    dataset_yaml: Path
    seed: int
    output_root: Path
    run_name: str
    epochs: int = 100
    patience: int = 20
    batch: int = 16
    device: int | str = 0
    mosaic: float = 1.0
    close_mosaic: int = 10
    translate: float = 0.1
    scale: float = 0.5


@dataclass(frozen=True)
class DetectorCandidateConfig:
    name: str
    initial_weights: Path
    fold_dataset_root: Path
    output_root: Path
    seed: int = 20260714
    epochs: int = 100
    patience: int = 20
    batch: int = 16
    device: int | str = 0
    synthetic_ratio: float = 0.0
    folds: tuple[int, ...] = (0, 1, 2, 3, 4)
    mosaic: float = 1.0
    close_mosaic: int = 10
    translate: float = 0.1
    scale: float = 0.5


@dataclass(frozen=True)
class DetectorCandidateReport:
    name: str
    fold_artifacts: tuple[dict[str, Any], ...]
    report: DetectorReport
    median_latency_ms: float
    best_epochs: tuple[int, ...]

    @property
    def fold_predictions(self) -> tuple[dict[str, Any], ...]:
        return self.fold_artifacts


def detector_candidate_matrix(
    current_weights: Path, fold_dataset_root: Path, output_root: Path
) -> tuple[DetectorCandidateConfig, DetectorCandidateConfig]:
    return (
        DetectorCandidateConfig(
            name="current_finetune_real",
            initial_weights=current_weights,
            fold_dataset_root=fold_dataset_root,
            output_root=output_root / "current_finetune_real",
        ),
        DetectorCandidateConfig(
            name="coco_yolov8n_real",
            initial_weights=Path("yolov8n.pt"),
            fold_dataset_root=fold_dataset_root,
            output_root=output_root / "coco_yolov8n_real",
        ),
    )


def fast_detector_candidate_matrix(
    current_weights: Path, fold_dataset_root: Path, output_root: Path
) -> tuple[DetectorCandidateConfig, DetectorCandidateConfig]:
    common = {
        "fold_dataset_root": fold_dataset_root,
        "folds": (0,),
        "epochs": 12,
        "patience": 4,
    }
    return (
        DetectorCandidateConfig(
            name="candidate_a2_tight",
            initial_weights=current_weights,
            output_root=output_root / "candidate_a2_tight",
            mosaic=0.25,
            close_mosaic=6,
            translate=0.05,
            scale=0.20,
            **common,
        ),
        DetectorCandidateConfig(
            name="candidate_b2_recall",
            initial_weights=Path("yolov8n.pt"),
            output_root=output_root / "candidate_b2_recall",
            mosaic=0.50,
            close_mosaic=8,
            translate=0.10,
            scale=0.30,
            **common,
        ),
    )


@dataclass(frozen=True)
class ClassifierTrainConfig:
    initial_weights: Path
    dataset_dir: Path
    seed: int
    output_root: Path
    run_name: str
    epochs: int = 50
    patience: int = 10
    batch: int = 64
    device: int | str = 0


@dataclass(frozen=True)
class ClassifierFoldManifest:
    fold: int
    validation_fold: int
    held_out_mixed_keys: tuple[str, ...]
    validation_mixed_keys: tuple[str, ...]
    training_mixed_keys: tuple[str, ...]
    validation_single_keys: tuple[str, ...]
    training_single_keys: tuple[str, ...]


def build_classifier_fold_manifest(
    catalog: Mapping[str, Any], split: Mapping[str, Any], fold: int
) -> ClassifierFoldManifest:
    folds = int(split["folds"])
    if fold not in range(folds):
        raise ValueError("classifier fold is outside the declared split")
    validation_fold = (fold + 1) % folds
    mixed_assignments = {
        str(key): int(value) for key, value in split["mixed_assignments"].items()
    }
    single_assignments = {
        str(key): int(value)
        for key, value in split["single_product_assignments"].items()
    }
    mixed_keys = {
        str(item["key"])
        for item in catalog["images"]
        if item["source_kind"] == "mixed_scene"
    }
    single_keys = {
        str(item["key"])
        for item in catalog["images"]
        if item["source_kind"] == "single_bread"
    }
    if mixed_keys != set(mixed_assignments):
        raise ValueError("catalog mixed images and split assignments do not match")
    if single_keys != set(single_assignments):
        raise ValueError("catalog single images and auxiliary assignments do not match")
    held_out = tuple(
        sorted(key for key in mixed_keys if mixed_assignments[key] == fold)
    )
    validation_mixed = tuple(
        sorted(key for key in mixed_keys if mixed_assignments[key] == validation_fold)
    )
    training_mixed = tuple(
        sorted(
            key
            for key in mixed_keys
            if mixed_assignments[key] not in {fold, validation_fold}
        )
    )
    validation_single = tuple(
        sorted(key for key in single_keys if single_assignments[key] == validation_fold)
    )
    training_single = tuple(
        sorted(
            key
            for key in single_keys
            if single_assignments[key] not in {fold, validation_fold}
        )
    )
    if set(held_out) & (set(training_mixed) | set(validation_mixed)):
        raise AssertionError("held-out mixed images leaked into classifier train/val")
    return ClassifierFoldManifest(
        fold=fold,
        validation_fold=validation_fold,
        held_out_mixed_keys=held_out,
        validation_mixed_keys=validation_mixed,
        training_mixed_keys=training_mixed,
        validation_single_keys=validation_single,
        training_single_keys=training_single,
    )


@dataclass(frozen=True)
class Prediction:
    bbox: BBox
    confidence: float


PredictionMap = Mapping[str, Sequence[Prediction]]
PredictFunction = Callable[[Sequence[str], float], PredictionMap]


def _yolo_class() -> Any:
    try:
        from ultralytics import YOLO
    except (ImportError, OSError) as error:
        raise RuntimeError(
            "Could not load the optional Ultralytics runtime: " + str(error)
        ) from error
    return YOLO


def train_detector_fold(
    config: DetectorTrainConfig, yolo_factory: Callable[[str], Any] | None = None
) -> Path:
    YOLO = yolo_factory or _yolo_class()
    model = YOLO(str(config.initial_weights))
    result = model.train(
        data=str(config.dataset_yaml),
        imgsz=640,
        device=config.device,
        seed=config.seed,
        deterministic=True,
        workers=0,
        batch=config.batch,
        epochs=config.epochs,
        patience=config.patience,
        project=str(config.output_root),
        name=config.run_name,
        exist_ok=True,
        mosaic=config.mosaic,
        close_mosaic=config.close_mosaic,
        translate=config.translate,
        scale=config.scale,
    )
    return Path(result.save_dir) / "weights" / "best.pt"


def train_classifier_fold(config: ClassifierTrainConfig) -> Path:
    if config.epochs <= 0:
        raise ValueError("classifier epochs must be positive")
    YOLO = _yolo_class()
    model = YOLO(str(config.initial_weights))
    result = model.train(
        data=str(config.dataset_dir),
        imgsz=224,
        device=config.device,
        seed=config.seed,
        deterministic=True,
        epochs=config.epochs,
        patience=config.patience,
        batch=config.batch,
        workers=0,
        project=str(config.output_root),
        name=config.run_name,
        exist_ok=True,
    )
    return Path(result.save_dir) / "weights" / "best.pt"


def _normalized_class_name(value: str) -> str:
    normalized = "".join(character for character in value.lower() if character.isalnum())
    if normalized.endswith("scone"):
        normalized = normalized[: -len("scone")] + "scon"
    return normalized


def classifier_class_map(
    model_names: Mapping[int, str], labels: Sequence[Mapping[str, Any]]
) -> tuple[dict[int, int], tuple[int, ...]]:
    canonical_names = {
        _normalized_class_name(str(label["name"])): int(label["id"])
        for label in labels
    }
    if len(canonical_names) != len(labels):
        raise ValueError("canonical classifier label names must be unique")
    canonical = dict(canonical_names)
    canonical.update(
        {
            f"{int(label['id']):02d}{_normalized_class_name(str(label['name']))}": int(label["id"])
            for label in labels
        }
    )
    mapping: dict[int, int] = {}
    for model_index, model_name in model_names.items():
        normalized = _normalized_class_name(str(model_name))
        if normalized not in canonical:
            raise ValueError(f"classifier class is not canonical: {model_name}")
        mapping[int(model_index)] = canonical[normalized]
    missing = tuple(sorted(set(canonical_names.values()) - set(mapping.values())))
    return mapping, missing


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _decode_annotation_crop(image_path: Path, bbox: Sequence[float]) -> Any:
    try:
        import cv2
        import numpy as np
    except (ImportError, OSError) as error:
        raise RuntimeError("OpenCV and NumPy are required for classifier OOF") from error
    image = cv2.imdecode(np.fromfile(str(image_path), dtype=np.uint8), cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError(f"Could not decode classifier source image: {image_path}")
    x, y, width, height = (float(value) for value in bbox)
    left = max(0, math.floor(x))
    top = max(0, math.floor(y))
    right = min(image.shape[1], math.ceil(x + width))
    bottom = min(image.shape[0], math.ceil(y + height))
    if right <= left or bottom <= top:
        raise ValueError(f"Classifier crop is empty for image: {image_path}")
    return image[top:bottom, left:right]


class _UltralyticsClassifierPredictor:
    def __init__(
        self,
        weights: Path,
        labels: Sequence[Mapping[str, Any]],
        device: str | int = "cpu",
    ):
        YOLO = _yolo_class()
        self._model = YOLO(str(weights))
        self._device = device
        self._class_map, self.missing_classes = classifier_class_map(
            self._model.names, labels
        )

    def predict(
        self, crops: Sequence[Any], batch_size: int = 64
    ) -> tuple[tuple[int, float, float, tuple[int, ...], float], ...]:
        predictions: list[tuple[int, float, float, tuple[int, ...], float]] = []
        for offset in range(0, len(crops), batch_size):
            batch = list(crops[offset : offset + batch_size])
            started = time.perf_counter()
            results = self._model.predict(
                source=batch,
                imgsz=224,
                device=self._device,
                verbose=False,
                stream=False,
            )
            elapsed_per_crop = (time.perf_counter() - started) * 1000 / len(batch)
            if len(results) != len(batch):
                raise RuntimeError("Ultralytics returned a different classifier result count")
            for result in results:
                probabilities = tuple(float(value) for value in result.probs.data.cpu().tolist())
                ranked = sorted(
                    range(len(probabilities)),
                    key=lambda index: (-probabilities[index], index),
                )
                if not ranked or ranked[0] not in self._class_map:
                    raise RuntimeError("Classifier returned an unmapped class")
                top_ids = tuple(self._class_map[index] for index in ranked[:3])
                confidence = probabilities[ranked[0]]
                second = probabilities[ranked[1]] if len(ranked) > 1 else 0.0
                predictions.append(
                    (top_ids[0], confidence, confidence - second, top_ids, elapsed_per_crop)
                )
        return tuple(predictions)


def _guard_output_root(output_root: Path) -> Path:
    resolved = output_root.resolve()
    allowed = (REPOSITORY_ROOT / "outputs").resolve()
    try:
        resolved.relative_to(allowed)
    except ValueError as error:
        raise ValueError(f"Output must be under {allowed}") from error
    return resolved


def run_classifier_baseline(
    catalog_path: Path,
    split_path: Path,
    single_root: Path,
    output_root: Path,
    baseline_weights: Path | None = None,
) -> Path:
    """Evaluate the preserved classifier on fold-partitioned real GT crops.

    The preserved weight has incomplete provenance, so artifacts explicitly mark
    this as a non-leakage-safe baseline rather than a newly trained OOF claim.
    """

    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    split = json.loads(split_path.read_text(encoding="utf-8"))
    if not single_root.is_dir():
        raise FileNotFoundError(f"Single-product root does not exist: {single_root}")
    if Path(catalog["raw_root"]).resolve() != single_root.resolve():
        raise ValueError("single-root must match the catalog raw_root")
    output_root = _guard_output_root(output_root)
    output_root.mkdir(parents=True, exist_ok=True)
    weights = (
        baseline_weights
        if baseline_weights is not None
        else REPOSITORY_ROOT / "models" / "bread_classifier_yolov8n_cls_best.pt"
    )
    if not weights.is_file():
        raise FileNotFoundError(f"Classifier baseline does not exist: {weights}")

    images = {item["key"]: item for item in catalog["images"]}
    assignments = {
        str(key): int(value) for key, value in split["mixed_assignments"].items()
    }
    records: list[dict[str, Any]] = []
    crops: list[Any] = []
    for annotation in sorted(catalog["annotations"], key=lambda item: item["annotation_id"]):
        image_key = annotation["image_key"]
        if image_key not in assignments:
            raise ValueError(f"Annotation image is not in the OOF split: {image_key}")
        image_path = Path(images[image_key]["absolute_path"])
        crops.append(_decode_annotation_crop(image_path, annotation["bbox"]))
        records.append(
            {
                "sample_id": annotation["annotation_id"],
                "fold": assignments[image_key],
                "image_key": image_key,
                "image_path": str(image_path),
                "bbox": [float(value) for value in annotation["bbox"]],
                "true_class": int(annotation["category_id"]),
            }
        )

    predictor = _UltralyticsClassifierPredictor(weights, catalog["labels"])
    raw_predictions = predictor.predict(crops)
    predictions: list[ClassificationPrediction] = []
    for record, raw in zip(records, raw_predictions):
        predicted_class, confidence, margin, top3, latency_ms = raw
        record.update(
            {
                "predicted_class": predicted_class,
                "confidence": confidence,
                "margin": margin,
                "top3": list(top3),
                "classifier_latency_ms": latency_ms,
            }
        )
        predictions.append(
            ClassificationPrediction(
                sample_id=record["sample_id"],
                true_class=record["true_class"],
                predicted_class=predicted_class,
                confidence=confidence,
                margin=margin,
                top3=top3,
            )
        )
    calibrated = calibrate_auto_label(predictions, min_precision=0.94)
    policy = LabelPolicy(
        version=calibrated.version,
        confidence=calibrated.confidence,
        margin=calibrated.margin,
        conservative_classes=tuple(
            sorted(set(calibrated.conservative_classes) | set(predictor.missing_classes))
        ),
    )
    for record, prediction in zip(records, predictions):
        record["classifier_ambiguous"] = (
            prediction.predicted_class in policy.conservative_classes
            or is_ambiguous(prediction.confidence, prediction.margin, policy)
        )

    predictions_path = output_root / "oof_predictions.jsonl"
    predictions_path.write_text(
        "".join(json.dumps(record, ensure_ascii=False) + "\n" for record in records),
        encoding="utf-8",
    )
    fold_reports = {
        str(fold): classifier_report(
            tuple(
                prediction
                for prediction, record in zip(predictions, records)
                if record["fold"] == fold
            ),
            policy,
        )
        for fold in range(int(split["folds"]))
    }
    report = classifier_report(predictions, policy)
    report.update(
        {
            "schema_version": 1,
            "evaluation_kind": "preserved_weight_fold_partitioned_baseline",
            "leakage_safe_oof": False,
            "provenance_warning": (
                "Preserved research weight training provenance is incomplete; "
                "metrics are a baseline bake-off and not a leakage-safe OOF claim."
            ),
            "model": str(weights.resolve()),
            "model_sha256": _sha256_file(weights),
            "sample_count": len(records),
            "missing_model_classes": list(predictor.missing_classes),
            "policy": asdict(policy),
            "folds": fold_reports,
            "latency_ms": {
                "p50": statistics.median(item[4] for item in raw_predictions),
                "p95": sorted(item[4] for item in raw_predictions)[
                    min(len(raw_predictions) - 1, math.ceil(len(raw_predictions) * 0.95) - 1)
                ],
            },
        }
    )
    report_path = output_root / "classifier_report.json"
    report_path.write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    single_assignments = split["single_product_assignments"]
    single_images = tuple(
        item for item in catalog["images"] if item["source_kind"] == "single_bread"
    )
    prototype_sources: dict[str, dict[str, list[str]]] = {}
    for fold in range(int(split["folds"])):
        by_class: dict[str, list[str]] = {}
        for class_id in sorted(int(label["id"]) for label in catalog["labels"]):
            eligible = sorted(
                str(item["absolute_path"])
                for item in single_images
                if int(item["category_id"]) == class_id
                and int(single_assignments[item["key"]]) != fold
            )
            by_class[str(class_id)] = eligible[:5]
        prototype_sources[str(fold)] = by_class
    context_path = output_root / "verifier_context.json"
    context_path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "classifier_weights": str(weights.resolve()),
                "classifier_sha256": _sha256_file(weights),
                "prototype_source_cap_per_class": 5,
                "prototype_sources": prototype_sources,
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    return report_path


def _class_directory(label: Mapping[str, Any]) -> str:
    name = "_".join(
        part for part in "".join(
            character.lower() if character.isalnum() else " "
            for character in str(label["name"])
        ).split()
    )
    return f"{int(label['id']):02d}_{name}"


def _link_or_copy(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.link(source, destination)
    except OSError:
        shutil.copy2(source, destination)


def _write_classifier_crop(
    image_path: Path, bbox: Sequence[float], destination: Path
) -> None:
    try:
        import cv2
    except (ImportError, OSError) as error:
        raise RuntimeError("OpenCV is required for classifier datasets") from error
    crop = _decode_annotation_crop(image_path, bbox)
    encoded, data = cv2.imencode(".jpg", crop, [int(cv2.IMWRITE_JPEG_QUALITY), 95])
    if not encoded:
        raise ValueError(f"Could not encode classifier crop: {image_path}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    data.tofile(str(destination))


def materialize_classifier_fold(
    catalog: Mapping[str, Any],
    split: Mapping[str, Any],
    fold: int,
    output_root: Path,
) -> tuple[ClassifierFoldManifest, Path, Path]:
    output_root = _guard_output_root(output_root)
    manifest = build_classifier_fold_manifest(catalog, split, fold)
    fold_root = output_root / f"fold_{fold}"
    dataset_root = fold_root / "dataset"
    if dataset_root.exists():
        resolved_dataset = dataset_root.resolve()
        try:
            resolved_dataset.relative_to(output_root)
        except ValueError as error:
            raise ValueError("Refusing to replace classifier data outside output root") from error
        shutil.rmtree(resolved_dataset)
    labels = {int(item["id"]): item for item in catalog["labels"]}
    class_directories = {
        class_id: _class_directory(label) for class_id, label in labels.items()
    }
    for split_name in ("train", "val"):
        for directory in class_directories.values():
            (dataset_root / split_name / directory).mkdir(parents=True, exist_ok=True)
    images = {str(item["key"]): item for item in catalog["images"]}
    source_records: list[dict[str, Any]] = []
    for split_name, keys in (
        ("train", manifest.training_single_keys),
        ("val", manifest.validation_single_keys),
    ):
        for key in keys:
            image = images[key]
            class_id = int(image["category_id"])
            source = Path(image["absolute_path"])
            suffix = source.suffix.lower() or ".jpg"
            destination = (
                dataset_root
                / split_name
                / class_directories[class_id]
                / f"single_{str(image['sha256'])[:20]}{suffix}"
            )
            _link_or_copy(source, destination)
            source_records.append(
                {
                    "split": split_name,
                    "source_kind": "single_bread",
                    "image_key": key,
                    "category_id": class_id,
                    "path": str(destination),
                }
            )
    training_mixed = set(manifest.training_mixed_keys)
    validation_mixed = set(manifest.validation_mixed_keys)
    for annotation in sorted(catalog["annotations"], key=lambda item: item["annotation_id"]):
        image_key = str(annotation["image_key"])
        if image_key in training_mixed:
            split_name = "train"
        elif image_key in validation_mixed:
            split_name = "val"
        else:
            continue
        class_id = int(annotation["category_id"])
        token = "".join(
            character if character.isalnum() else "_"
            for character in str(annotation["annotation_id"])
        )
        destination = (
            dataset_root
            / split_name
            / class_directories[class_id]
            / f"mixed_{token}.jpg"
        )
        _write_classifier_crop(
            Path(images[image_key]["absolute_path"]), annotation["bbox"], destination
        )
        source_records.append(
            {
                "split": split_name,
                "source_kind": "mixed_crop",
                "image_key": image_key,
                "annotation_id": annotation["annotation_id"],
                "category_id": class_id,
                "path": str(destination),
            }
        )
    counts: dict[str, dict[str, int]] = {"train": {}, "val": {}}
    for split_name in counts:
        for class_id, directory in class_directories.items():
            count = len(tuple((dataset_root / split_name / directory).iterdir()))
            if count == 0:
                raise ValueError(
                    f"Classifier fold {fold} has no {split_name} samples for class {class_id}"
                )
            counts[split_name][str(class_id)] = count
    manifest_path = fold_root / "fold_manifest.json"
    manifest_path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                **asdict(manifest),
                "held_out_absent_from_train_val": not bool(
                    set(manifest.held_out_mixed_keys)
                    & (
                        set(manifest.training_mixed_keys)
                        | set(manifest.validation_mixed_keys)
                    )
                ),
                "class_directories": {
                    str(key): value for key, value in class_directories.items()
                },
                "counts": counts,
                "sources": source_records,
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    return manifest, dataset_root, manifest_path


def _classification_records(
    predictor: _UltralyticsClassifierPredictor,
    annotations: Sequence[Mapping[str, Any]],
    images: Mapping[str, Mapping[str, Any]],
    fold: int,
    role: str,
) -> tuple[list[dict[str, Any]], list[ClassificationPrediction]]:
    records: list[dict[str, Any]] = []
    crops: list[Any] = []
    for annotation in sorted(annotations, key=lambda item: item["annotation_id"]):
        image_key = str(annotation["image_key"])
        image_path = Path(images[image_key]["absolute_path"])
        crops.append(_decode_annotation_crop(image_path, annotation["bbox"]))
        records.append(
            {
                "sample_id": annotation["annotation_id"],
                "fold": fold,
                "role": role,
                "image_key": image_key,
                "image_path": str(image_path),
                "bbox": [float(value) for value in annotation["bbox"]],
                "true_class": int(annotation["category_id"]),
            }
        )
    raw_predictions = predictor.predict(crops)
    predictions: list[ClassificationPrediction] = []
    for record, raw in zip(records, raw_predictions):
        predicted_class, confidence, margin, top3, latency_ms = raw
        record.update(
            {
                "predicted_class": predicted_class,
                "confidence": confidence,
                "margin": margin,
                "top3": list(top3),
                "classifier_latency_ms": latency_ms,
            }
        )
        predictions.append(
            ClassificationPrediction(
                sample_id=record["sample_id"],
                true_class=record["true_class"],
                predicted_class=predicted_class,
                confidence=confidence,
                margin=margin,
                top3=top3,
            )
        )
    return records, predictions


def _single_validation_records(
    predictor: _UltralyticsClassifierPredictor,
    keys: Sequence[str],
    images: Mapping[str, Mapping[str, Any]],
    fold: int,
) -> tuple[list[dict[str, Any]], list[ClassificationPrediction]]:
    records: list[dict[str, Any]] = []
    crops: list[Any] = []
    for key in sorted(keys):
        image = images[key]
        image_path = Path(image["absolute_path"])
        crops.append(
            _decode_annotation_crop(
                image_path, (0.0, 0.0, float(image["width"]), float(image["height"]))
            )
        )
        records.append(
            {
                "sample_id": f"single:{key}",
                "fold": fold,
                "role": "validation_single",
                "image_key": key,
                "image_path": str(image_path),
                "true_class": int(image["category_id"]),
            }
        )
    raw_predictions = predictor.predict(crops)
    predictions: list[ClassificationPrediction] = []
    for record, raw in zip(records, raw_predictions):
        predicted_class, confidence, margin, top3, latency_ms = raw
        record.update(
            {
                "predicted_class": predicted_class,
                "confidence": confidence,
                "margin": margin,
                "top3": list(top3),
                "classifier_latency_ms": latency_ms,
            }
        )
        predictions.append(
            ClassificationPrediction(
                sample_id=record["sample_id"],
                true_class=record["true_class"],
                predicted_class=predicted_class,
                confidence=confidence,
                margin=margin,
                top3=top3,
            )
        )
    return records, predictions


def run_classifier_oof(
    catalog_path: Path,
    split_path: Path,
    single_root: Path,
    output_root: Path,
    initial_weights: Path = DEFAULT_CLASSIFIER_INITIAL_WEIGHTS,
    epochs: int = 50,
    patience: int = 10,
    reuse_trained_folds: bool = False,
) -> Path:
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    split = json.loads(split_path.read_text(encoding="utf-8"))
    if Path(catalog["raw_root"]).resolve() != single_root.resolve():
        raise ValueError("single-root must match the catalog raw_root")
    output_root = _guard_output_root(output_root)
    output_root.mkdir(parents=True, exist_ok=True)
    images = {str(item["key"]): item for item in catalog["images"]}
    annotations = tuple(catalog["annotations"])
    held_out_records: list[dict[str, Any]] = []
    held_out_predictions: list[ClassificationPrediction] = []
    validation_predictions: list[ClassificationPrediction] = []
    fold_artifacts: list[dict[str, Any]] = []
    fold_manifests: list[ClassifierFoldManifest] = []
    policies_by_fold: dict[int, LabelPolicy] = {}
    weights_by_fold: dict[str, str] = {}
    folds = int(split["folds"])
    for fold in range(folds):
        manifest, dataset_root, manifest_path = materialize_classifier_fold(
            catalog, split, fold, output_root
        )
        fold_manifests.append(manifest)
        existing_best = output_root / f"fold_{fold}" / "train" / "weights" / "best.pt"
        if reuse_trained_folds and existing_best.is_file():
            best = existing_best
        else:
            best = train_classifier_fold(
                ClassifierTrainConfig(
                    initial_weights=initial_weights,
                    dataset_dir=dataset_root,
                    seed=20260714,
                    output_root=output_root / f"fold_{fold}",
                    run_name="train",
                    epochs=epochs,
                    patience=patience,
                    batch=64,
                    device=0,
                )
            )
        predictor = _UltralyticsClassifierPredictor(
            best, catalog["labels"], device=0
        )
        if predictor.missing_classes:
            raise RuntimeError(
                f"Trained classifier fold {fold} is missing canonical classes: "
                f"{predictor.missing_classes}"
            )
        validation_keys = set(manifest.validation_mixed_keys)
        held_out_keys = set(manifest.held_out_mixed_keys)
        validation_records, fold_validation_predictions = _classification_records(
            predictor,
            tuple(item for item in annotations if item["image_key"] in validation_keys),
            images,
            fold,
            "validation",
        )
        single_validation_records, single_validation_predictions = (
            _single_validation_records(
                predictor,
                manifest.validation_single_keys,
                images,
                fold,
            )
        )
        validation_records.extend(single_validation_records)
        fold_validation_predictions.extend(single_validation_predictions)
        fold_held_out_records, fold_held_out_predictions = _classification_records(
            predictor,
            tuple(item for item in annotations if item["image_key"] in held_out_keys),
            images,
            fold,
            "held_out",
        )
        validation_predictions.extend(fold_validation_predictions)
        held_out_records.extend(fold_held_out_records)
        held_out_predictions.extend(fold_held_out_predictions)
        fold_policy = calibrate_auto_label(
            fold_validation_predictions, min_precision=0.94
        )
        policies_by_fold[fold] = fold_policy
        fold_artifact_path = output_root / f"fold_{fold}" / "evaluation.json"
        fold_artifact_path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "fold": fold,
                    "validation_fold": manifest.validation_fold,
                    "threshold_selected_from": list(manifest.validation_mixed_keys),
                    "held_out_keys": list(manifest.held_out_mixed_keys),
                    "fold_policy": asdict(fold_policy),
                    "validation_records": validation_records,
                    "held_out_records": fold_held_out_records,
                },
                indent=2,
                ensure_ascii=False,
            )
            + "\n",
            encoding="utf-8",
        )
        weights_by_fold[str(fold)] = str(best.resolve())
        fold_artifacts.append(
            {
                "fold": fold,
                "validation_fold": manifest.validation_fold,
                "manifest": str(manifest_path),
                "weights": str(best.resolve()),
                "weights_sha256": _sha256_file(best),
                "fold_policy": asdict(fold_policy),
            }
        )
    deployment_policy = derive_deployment_policy(
        policies_by_fold[fold] for fold in sorted(policies_by_fold)
    )
    for record, prediction in zip(held_out_records, held_out_predictions):
        record["classifier_ambiguous"] = (
            prediction.predicted_class in deployment_policy.conservative_classes
            or is_ambiguous(
                prediction.confidence, prediction.margin, deployment_policy
            )
        )
    predictions_path = output_root / "oof_predictions.jsonl"
    predictions_path.write_text(
        "".join(
            json.dumps(record, ensure_ascii=False) + "\n"
            for record in held_out_records
        ),
        encoding="utf-8",
    )
    report = classifier_report(held_out_predictions, deployment_policy)
    deployment_report = deployment_policy_report(
        held_out_predictions, deployment_policy
    )
    report["white_auto_precision"] = deployment_report["precision"]
    report["white_coverage"] = deployment_report["coverage"]
    report["red_review_rate"] = deployment_report["redReviewRate"]
    report.update(
        {
            "schema_version": 2,
            "evaluation_kind": "new_20_class_leakage_safe_5fold_oof",
            "leakage_safe_oof": True,
            "initial_weights": str(initial_weights),
            "seed": 20260714,
            "imgsz": 224,
            "device": "cuda:0",
            "epochs_requested": epochs,
            "patience": patience,
            "sample_count": len(held_out_records),
            "calibration_sample_count": len(validation_predictions),
            "policy": asdict(deployment_policy),
            "policy_selection_source": "median_of_five_validation_fold_policies",
            "deployment_policy_report": deployment_report,
            "folds": fold_artifacts,
            "latency_ms": {
                "p50": statistics.median(
                    record["classifier_latency_ms"] for record in held_out_records
                ),
                "p95": _percentile_nearest(
                    tuple(
                        record["classifier_latency_ms"] for record in held_out_records
                    ),
                    0.95,
                ),
            },
        }
    )
    report_path = output_root / "classifier_report.json"
    report_path.write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    single_images = {
        str(item["key"]): item
        for item in catalog["images"]
        if item["source_kind"] == "single_bread"
    }
    prototype_sources: dict[str, dict[str, list[str]]] = {}
    for manifest in fold_manifests:
        allowed = set(manifest.training_single_keys)
        by_class: dict[str, list[str]] = {}
        for label in catalog["labels"]:
            class_id = int(label["id"])
            by_class[str(class_id)] = sorted(
                str(item["absolute_path"])
                for key, item in single_images.items()
                if key in allowed and int(item["category_id"]) == class_id
            )[:5]
        prototype_sources[str(manifest.fold)] = by_class
    (output_root / "verifier_context.json").write_text(
        json.dumps(
            {
                "schema_version": 2,
                "classifier_weights_by_fold": weights_by_fold,
                "prototype_source_cap_per_class": 5,
                "prototype_sources": prototype_sources,
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    return report_path


def _percentile_nearest(values: Sequence[float], percentile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, math.ceil(len(ordered) * percentile) - 1)]


def _filtered_predictions(
    predictions: PredictionMap, confidence_threshold: float
) -> dict[str, tuple[Prediction, ...]]:
    return {
        image_key: tuple(
            prediction
            for prediction in image_predictions
            if prediction.confidence >= confidence_threshold
        )
        for image_key, image_predictions in predictions.items()
    }


def _average_precision(
    ground_truth: Mapping[str, Sequence[BBox]],
    predictions: PredictionMap,
    iou_threshold: float,
) -> float:
    ground_truth_count = sum(len(boxes) for boxes in ground_truth.values())
    if ground_truth_count == 0:
        return 0.0
    ranked = sorted(
        (
            (-prediction.confidence, image_key, index, prediction)
            for image_key, image_predictions in predictions.items()
            for index, prediction in enumerate(image_predictions)
        ),
        key=lambda item: (item[0], item[1], item[2]),
    )
    consumed: dict[str, set[int]] = {key: set() for key in ground_truth}
    true_positives: list[int] = []
    false_positives: list[int] = []
    for _, image_key, _, prediction in ranked:
        best: tuple[float, int] | None = None
        for gt_index, gt_box in enumerate(ground_truth.get(image_key, ())):
            if gt_index in consumed.setdefault(image_key, set()):
                continue
            one_match = match_detections(
                (gt_box,), (prediction,), iou_threshold=iou_threshold
            )
            if one_match.matches:
                candidate = (one_match.matched_ious[0], -gt_index)
                if best is None or candidate > best:
                    best = candidate
        if best is None:
            true_positives.append(0)
            false_positives.append(1)
        else:
            consumed[image_key].add(-best[1])
            true_positives.append(1)
            false_positives.append(0)

    cumulative_tp: list[int] = []
    cumulative_fp: list[int] = []
    tp = fp = 0
    for is_tp, is_fp in zip(true_positives, false_positives):
        tp += is_tp
        fp += is_fp
        cumulative_tp.append(tp)
        cumulative_fp.append(fp)
    precisions = [
        matched / (matched + extra)
        for matched, extra in zip(cumulative_tp, cumulative_fp)
    ]
    recalls = [matched / ground_truth_count for matched in cumulative_tp]
    samples = []
    for recall_level in (value / 100 for value in range(101)):
        samples.append(
            max(
                (
                    precision
                    for recall, precision in zip(recalls, precisions)
                    if recall >= recall_level
                ),
                default=0.0,
            )
        )
    return statistics.fmean(samples)


def evaluate_predictions(
    ground_truth: Mapping[str, Sequence[BBox]],
    predictions: PredictionMap,
    *,
    ap_predictions: PredictionMap | None = None,
) -> DetectorReport:
    total_ground_truth = 0
    total_predictions = 0
    total_matches = 0
    matched_ious: list[float] = []
    area_ratios: list[float] = []
    for image_key in sorted(set(ground_truth) | set(predictions)):
        image_ground_truth = ground_truth.get(image_key, ())
        image_predictions = predictions.get(image_key, ())
        result = match_detections(image_ground_truth, image_predictions)
        total_ground_truth += result.ground_truth_count
        total_predictions += result.prediction_count
        total_matches += result.matches
        matched_ious.extend(result.matched_ious)
        area_ratios.extend(result.matched_area_ratios)
    ranked_predictions = (
        ap_predictions if ap_predictions is not None else predictions
    )
    map50_95 = statistics.fmean(
        _average_precision(ground_truth, ranked_predictions, threshold / 100)
        for threshold in range(50, 100, 5)
    )
    return DetectorReport(
        recall=total_matches / total_ground_truth if total_ground_truth else 0.0,
        precision=total_matches / total_predictions if total_predictions else 0.0,
        map50_95=map50_95,
        median_iou=statistics.median(matched_ious) if matched_ious else 0.0,
        median_area_ratio=(statistics.median(area_ratios) if area_ratios else 0.0),
    )


def select_confidence_threshold(
    ground_truth: Mapping[str, Sequence[BBox]],
    raw_predictions: PredictionMap,
    candidates: Sequence[float] = DEFAULT_THRESHOLD_CANDIDATES,
) -> float:
    if not candidates:
        raise ValueError("at least one confidence threshold candidate is required")
    invalid = [candidate for candidate in candidates if not 0.0 <= candidate <= 1.0]
    if invalid:
        raise ValueError("confidence thresholds must be between zero and one")
    scored: list[tuple[float, float, float, float]] = []
    for threshold in sorted(set(float(candidate) for candidate in candidates)):
        report = evaluate_predictions(
            ground_truth, _filtered_predictions(raw_predictions, threshold)
        )
        denominator = report.precision + report.recall
        f1 = (
            2 * report.precision * report.recall / denominator
            if denominator
            else 0.0
        )
        scored.append((f1, report.precision, report.recall, threshold))
    return max(scored)[3]


def _prediction_json(prediction: Prediction) -> dict[str, Any]:
    return {
        "bbox": list(prediction.bbox),
        "confidence": prediction.confidence,
    }


def evaluate_detector_fold(
    *,
    fold: int,
    validation_keys: Sequence[str],
    held_out_keys: Sequence[str],
    ground_truth: Mapping[str, Sequence[BBox]],
    predict: PredictFunction,
    artifact_path: Path,
    threshold_candidates: Sequence[float] = DEFAULT_THRESHOLD_CANDIDATES,
    clock: Callable[[], float] = time.perf_counter,
    latency_records: dict[str, float] | None = None,
) -> DetectorReport:
    """Select on train-side data, then run held-out inference with a frozen value."""

    validation_keys = tuple(sorted(validation_keys))
    held_out_keys = tuple(sorted(held_out_keys))
    if set(validation_keys) & set(held_out_keys):
        raise ValueError("train-side validation and held-out image keys must be disjoint")
    raw_validation_predictions = predict(validation_keys, AP_CONFIDENCE_FLOOR)
    threshold = select_confidence_threshold(
        {key: ground_truth.get(key, ()) for key in validation_keys},
        raw_validation_predictions,
        threshold_candidates,
    )
    raw_held_out_predictions: dict[str, tuple[Prediction, ...]] = {}
    held_out_latencies: dict[str, float] = {}
    for image_key in held_out_keys:
        started = clock()
        image_predictions = predict((image_key,), AP_CONFIDENCE_FLOOR)
        elapsed_ms = (clock() - started) * 1000
        raw_held_out_predictions[image_key] = tuple(
            image_predictions.get(image_key, ())
        )
        held_out_latencies[image_key] = elapsed_ms
    if latency_records is not None:
        latency_records.update(held_out_latencies)
    operational_predictions = _filtered_predictions(
        raw_held_out_predictions, threshold
    )
    held_out_ground_truth = {
        key: tuple(ground_truth.get(key, ())) for key in held_out_keys
    }
    report = evaluate_predictions(
        held_out_ground_truth,
        operational_predictions,
        ap_predictions=raw_held_out_predictions,
    )
    payload = {
        "schema_version": 2,
        "fold": fold,
        "ap_confidence_floor": AP_CONFIDENCE_FLOOR,
        "confidence_threshold": threshold,
        "threshold_selected_from": list(validation_keys),
        "metrics": asdict(report),
        "images": [
            {
                "image_key": image_key,
                "ground_truth": [list(box) for box in held_out_ground_truth[image_key]],
                "raw_predictions": [
                    _prediction_json(prediction)
                    for prediction in raw_held_out_predictions.get(image_key, ())
                ],
                "operational_predictions": [
                    _prediction_json(prediction)
                    for prediction in operational_predictions.get(image_key, ())
                ],
                "latency_ms": held_out_latencies[image_key],
            }
            for image_key in held_out_keys
        ],
    }
    artifact_path.parent.mkdir(parents=True, exist_ok=True)
    artifact_path.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return report


class _UltralyticsPredictor:
    def __init__(
        self,
        weights: Path,
        paths_by_key: Mapping[str, Path],
        device: int | str = 0,
    ):
        YOLO = _yolo_class()
        self._model = YOLO(str(weights))
        self._paths_by_key = paths_by_key
        self._device = device

    def __call__(
        self, image_keys: Sequence[str], confidence: float
    ) -> dict[str, tuple[Prediction, ...]]:
        if not image_keys:
            return {}
        paths = [str(self._paths_by_key[key]) for key in image_keys]
        results = self._model.predict(
            source=paths,
            conf=max(confidence, AP_CONFIDENCE_FLOOR),
            imgsz=640,
            device=self._device,
            verbose=False,
            stream=False,
        )
        if len(results) != len(image_keys):
            raise RuntimeError("Ultralytics returned a different number of results")
        predictions: dict[str, tuple[Prediction, ...]] = {}
        for image_key, result in zip(image_keys, results):
            xyxy = result.boxes.xyxy.cpu().tolist()
            confidences = result.boxes.conf.cpu().tolist()
            image_predictions = []
            for coordinates, score in zip(xyxy, confidences):
                x1, y1, x2, y2 = (float(value) for value in coordinates)
                image_predictions.append(
                    Prediction((x1, y1, x2 - x1, y2 - y1), float(score))
                )
            predictions[image_key] = tuple(image_predictions)
        return predictions


def _candidate_fold_manifest(dataset_root: Path, fold: int) -> dict[str, Any]:
    manifest_path = dataset_root / "source_manifest.json"
    if not manifest_path.is_file():
        raise FileNotFoundError(f"Detector fold manifest does not exist: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("dataset_kind") != "fold" or manifest.get("heldout_fold") != fold:
        raise ValueError(f"Detector fold manifest identity mismatch: {manifest_path}")
    splits = manifest.get("splits")
    if not isinstance(splits, dict) or set(splits) != {"train", "validation", "test"}:
        raise ValueError(f"Detector fold manifest has invalid splits: {manifest_path}")
    for split_name, records in splits.items():
        if not isinstance(records, list):
            raise ValueError(f"Detector fold manifest split is invalid: {split_name}")
        for record in records:
            if not isinstance(record, dict):
                raise ValueError("Detector fold manifest record is invalid")
            if record.get("synthetic") or record.get("source_kind") == "synthetic":
                raise ValueError("Detector candidates must not contain synthetic records")
            for field in ("image_key", "output_image", "output_label"):
                if not isinstance(record.get(field), str) or not record[field]:
                    raise ValueError(f"Detector fold record is missing {field}")
    return manifest


def _dataset_record_path(dataset_root: Path, relative_value: str) -> Path:
    path = (dataset_root / Path(relative_value)).resolve()
    try:
        path.relative_to(dataset_root.resolve())
    except ValueError as error:
        raise ValueError("Detector fold manifest path escapes its dataset") from error
    return path


def _candidate_split_paths(
    dataset_root: Path, manifest: Mapping[str, Any], split: str
) -> dict[str, Path]:
    paths = {
        str(record["image_key"]): _dataset_record_path(
            dataset_root, str(record["output_image"])
        )
        for record in manifest["splits"][split]
    }
    missing = [str(path) for path in paths.values() if not path.is_file()]
    if missing:
        raise FileNotFoundError(f"Generated detector image does not exist: {missing[0]}")
    return paths


def _load_candidate_ground_truth(
    dataset_root: Path, split: str
) -> dict[str, tuple[BBox, ...]]:
    try:
        from PIL import Image, ImageOps
    except (ImportError, OSError) as error:
        raise RuntimeError("Pillow is required for detector candidate evaluation") from error
    manifest = _candidate_fold_manifest(
        dataset_root, int(dataset_root.name.removeprefix("fold_"))
    )
    ground_truth: dict[str, tuple[BBox, ...]] = {}
    for record in manifest["splits"][split]:
        image_path = _dataset_record_path(dataset_root, record["output_image"])
        label_path = _dataset_record_path(dataset_root, record["output_label"])
        with Image.open(image_path) as image:
            width, height = ImageOps.exif_transpose(image).size
        boxes: list[BBox] = []
        if label_path.is_file():
            for line in label_path.read_text(encoding="utf-8").splitlines():
                values = line.split()
                if len(values) != 5 or values[0] != "0":
                    raise ValueError(f"Invalid one-class YOLO label: {label_path}")
                _, center_x, center_y, box_width, box_height = map(float, values)
                pixel_width = box_width * width
                pixel_height = box_height * height
                boxes.append(
                    (
                        center_x * width - pixel_width / 2,
                        center_y * height - pixel_height / 2,
                        pixel_width,
                        pixel_height,
                    )
                )
        ground_truth[str(record["image_key"])] = tuple(boxes)
    return ground_truth


def _best_epoch(run_root: Path) -> int:
    results_path = run_root / "results.csv"
    if not results_path.is_file():
        return 0
    with results_path.open("r", encoding="utf-8", newline="") as source:
        rows = list(csv.DictReader(source))
    if not rows:
        return 0
    normalized = [
        {str(key).strip(): str(value).strip() for key, value in row.items()}
        for row in rows
    ]
    map50_95 = "metrics/mAP50-95(B)"
    if all(map50_95 in row for row in normalized):
        selected = max(
            normalized,
            key=lambda row: (
                float(row[map50_95]),
                int(float(row["epoch"])),
            ),
        )
    else:
        selected = normalized[-1]
    return int(float(selected["epoch"]))


def _detector_report_from_payload(payload: Mapping[str, Any]) -> DetectorReport:
    return DetectorReport(**{key: float(value) for key, value in payload.items()})


def _ensure_candidate_initial_weights(path: Path) -> Path:
    if path.is_file() and path.stat().st_size > 0:
        return path
    if path == Path("yolov8n.pt"):
        _yolo_class()(str(path))
    if not path.is_file() or path.stat().st_size <= 0:
        raise FileNotFoundError(f"Detector initial weights do not exist: {path}")
    return path


def _training_fingerprint(
    config: DetectorCandidateConfig,
    *,
    initial_weights_sha256: str,
    dataset_manifest_sha256: str,
    dataset_yaml_sha256: str,
) -> dict[str, Any]:
    return {
        "trainer_schema_version": DETECTOR_CANDIDATE_TRAINER_SCHEMA_VERSION,
        "evaluator_schema_version": DETECTOR_CANDIDATE_EVALUATOR_VERSION,
        "candidate": config.name,
        "initial_weights": str(config.initial_weights),
        "initial_weights_sha256": initial_weights_sha256,
        "dataset_manifest_sha256": dataset_manifest_sha256,
        "dataset_yaml_sha256": dataset_yaml_sha256,
        "imgsz": 640,
        "device": config.device,
        "seed": config.seed,
        "deterministic": True,
        "workers": 0,
        "batch": config.batch,
        "epochs": config.epochs,
        "patience": config.patience,
        "synthetic_ratio": config.synthetic_ratio,
        "folds": list(config.folds),
        "mosaic": config.mosaic,
        "close_mosaic": config.close_mosaic,
        "translate": config.translate,
        "scale": config.scale,
        "exist_ok": True,
    }


def run_detector_candidate_oof(
    config: DetectorCandidateConfig,
    *,
    train_fold: Callable[[DetectorTrainConfig], Path] = train_detector_fold,
    predictor_factory: Callable[..., Any] = _UltralyticsPredictor,
    ground_truth_loader: Callable[
        [Path, str], Mapping[str, Sequence[BBox]]
    ] = _load_candidate_ground_truth,
    progress: Callable[[str], None] | None = print,
) -> DetectorCandidateReport:
    if config.synthetic_ratio != 0:
        raise ValueError("Detector candidate synthetic_ratio must be zero")
    if config.epochs <= 0 or config.patience < 0 or config.batch <= 0:
        raise ValueError("Detector candidate training settings are invalid")
    if (
        not config.folds
        or any(type(fold) is not int or fold not in range(5) for fold in config.folds)
        or len(set(config.folds)) != len(config.folds)
    ):
        raise ValueError("Detector candidate folds must be unique integers from 0 to 4")
    initial_weights = _ensure_candidate_initial_weights(config.initial_weights)
    initial_weights_hash = _sha256_file(initial_weights)
    fold_manifests = []
    heldout_keys: set[str] = set()
    for fold in config.folds:
        dataset_root = config.fold_dataset_root / f"fold_{fold}"
        manifest = _candidate_fold_manifest(dataset_root, fold)
        current_keys = {
            str(record["image_key"]) for record in manifest["splits"]["test"]
        }
        if heldout_keys & current_keys:
            raise ValueError("Detector held-out images must be unique across folds")
        heldout_keys.update(current_keys)
        fold_manifests.append((fold, dataset_root, manifest))

    config.output_root.mkdir(parents=True, exist_ok=True)
    fold_payloads: list[dict[str, Any]] = []
    fold_reports: list[DetectorReport] = []
    best_epochs: list[int] = []
    latencies: list[float] = []
    for fold, dataset_root, manifest in fold_manifests:
        manifest_path = dataset_root / "source_manifest.json"
        dataset_yaml = dataset_root / "dataset.yaml"
        if not dataset_yaml.is_file():
            raise FileNotFoundError(f"Detector dataset YAML does not exist: {dataset_yaml}")
        manifest_hash = _sha256_file(manifest_path)
        training_fingerprint = _training_fingerprint(
            config,
            initial_weights_sha256=initial_weights_hash,
            dataset_manifest_sha256=manifest_hash,
            dataset_yaml_sha256=_sha256_file(dataset_yaml),
        )
        run_name = f"fold_{fold}"
        run_root = config.output_root / run_name
        weights = run_root / "weights" / "best.pt"
        completion_path = run_root / "candidate_training.json"
        reusable = False
        if weights.is_file() and completion_path.is_file():
            try:
                loaded_completion = json.loads(
                    completion_path.read_text(encoding="utf-8")
                )
            except (json.JSONDecodeError, UnicodeDecodeError):
                loaded_completion = None
            stored_completion = (
                loaded_completion if isinstance(loaded_completion, dict) else {}
            )
            reusable = (
                weights.stat().st_size > 0
                and stored_completion.get("schema_version") == 2
                and stored_completion.get("fold") == fold
                and stored_completion.get("training_fingerprint")
                == training_fingerprint
                and stored_completion.get("best_weights_sha256")
                == _sha256_file(weights)
            )
        if not reusable:
            if progress:
                progress(f"candidate={config.name} fold={fold} phase=train")
            weights = train_fold(
                DetectorTrainConfig(
                    initial_weights=config.initial_weights,
                    dataset_yaml=dataset_yaml,
                    seed=config.seed,
                    output_root=config.output_root,
                    run_name=run_name,
                    epochs=config.epochs,
                    patience=config.patience,
                    batch=config.batch,
                    device=config.device,
                    mosaic=config.mosaic,
                    close_mosaic=config.close_mosaic,
                    translate=config.translate,
                    scale=config.scale,
                )
            )
            if not weights.is_file() or weights.stat().st_size <= 0:
                raise FileNotFoundError(f"Trained detector weights do not exist: {weights}")
            completion = {
                "schema_version": 2,
                "fold": fold,
                "training_fingerprint": training_fingerprint,
                "best_weights_sha256": _sha256_file(weights),
            }
            completion_path.parent.mkdir(parents=True, exist_ok=True)
            completion_path.write_text(
                json.dumps(completion, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
        elif progress:
            progress(f"candidate={config.name} fold={fold} phase=reuse-trained")

        validation_paths = _candidate_split_paths(dataset_root, manifest, "validation")
        test_paths = _candidate_split_paths(dataset_root, manifest, "test")
        predictor = predictor_factory(
            weights, {**validation_paths, **test_paths}, device=config.device
        )
        ground_truth = {
            **ground_truth_loader(dataset_root, "validation"),
            **ground_truth_loader(dataset_root, "test"),
        }
        artifact_path = config.output_root / f"fold_{fold}_predictions.json"
        model_hash = _sha256_file(weights)
        artifact_reusable = False
        if reusable and artifact_path.is_file():
            existing = json.loads(artifact_path.read_text(encoding="utf-8"))
            artifact_reusable = (
                existing.get("evaluator_version")
                == DETECTOR_CANDIDATE_EVALUATOR_VERSION
                and existing.get("model_sha256") == model_hash
                and existing.get("dataset_manifest_sha256") == manifest_hash
            )
        if not artifact_reusable:
            if progress:
                progress(f"candidate={config.name} fold={fold} phase=evaluate")
            fold_latency: dict[str, float] = {}
            evaluate_detector_fold(
                fold=fold,
                validation_keys=tuple(validation_paths),
                held_out_keys=tuple(test_paths),
                ground_truth=ground_truth,
                predict=predictor,
                artifact_path=artifact_path,
                latency_records=fold_latency,
            )
            payload = json.loads(artifact_path.read_text(encoding="utf-8"))
            payload.update(
                {
                    "candidate": config.name,
                    "evaluator_version": DETECTOR_CANDIDATE_EVALUATOR_VERSION,
                    "model": str(weights.resolve()),
                    "model_sha256": model_hash,
                    "dataset_manifest": str(manifest_path.resolve()),
                    "dataset_manifest_sha256": manifest_hash,
                    "threshold_selected_from_split": "validation",
                    "synthetic_record_count": 0,
                    "best_epoch": _best_epoch(run_root),
                }
            )
            artifact_path.write_text(
                json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
        else:
            payload = existing
            if progress:
                progress(f"candidate={config.name} fold={fold} phase=reuse-evaluation")
        report = _detector_report_from_payload(payload["metrics"])
        fold_payloads.append(payload)
        fold_reports.append(report)
        best_epochs.append(int(payload["best_epoch"]))
        latencies.extend(float(image["latency_ms"]) for image in payload["images"])
        if progress:
            progress(f"candidate={config.name} fold={fold} phase=complete")

    aggregate = detector_report(fold_reports)
    median_latency = statistics.median(latencies) if latencies else 0.0
    report_payload = {
        "schema_version": 1,
        "candidate": config.name,
        "aggregation": "paired_fold_mean",
        "ap_confidence_floor": AP_CONFIDENCE_FLOOR,
        "synthetic_ratio": config.synthetic_ratio,
        "heldout_image_count": len(heldout_keys),
        "best_epochs": best_epochs,
        "folds": [
            {
                "fold": int(payload["fold"]),
                "metrics": payload["metrics"],
                "confidence_threshold": payload["confidence_threshold"],
                "model_sha256": payload["model_sha256"],
                "dataset_manifest_sha256": payload["dataset_manifest_sha256"],
            }
            for payload in fold_payloads
        ],
        "metrics": asdict(aggregate),
        "median_latency_ms": median_latency,
    }
    (config.output_root / "candidate_report.json").write_text(
        json.dumps(report_payload, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return DetectorCandidateReport(
        name=config.name,
        fold_artifacts=tuple(fold_payloads),
        report=aggregate,
        median_latency_ms=median_latency,
        best_epochs=tuple(best_epochs),
    )


def _load_oof_inputs(
    catalog_path: Path, split_path: Path
) -> tuple[dict[str, Path], dict[str, tuple[BBox, ...]], dict[str, int], int]:
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    split = json.loads(split_path.read_text(encoding="utf-8"))
    paths = {
        image["key"]: Path(image["absolute_path"])
        for image in catalog["images"]
        if image["source_kind"] == "mixed_scene"
    }
    ground_truth_lists: dict[str, list[BBox]] = {key: [] for key in paths}
    for annotation in catalog["annotations"]:
        image_key = annotation["image_key"]
        if image_key in ground_truth_lists:
            ground_truth_lists[image_key].append(
                tuple(float(value) for value in annotation["bbox"])  # type: ignore[arg-type]
            )
    assignments = {
        str(key): int(value) for key, value in split["mixed_assignments"].items()
    }
    if set(paths) != set(assignments):
        raise ValueError("catalog mixed images and split assignments do not match")
    folds = int(split["folds"])
    if set(assignments.values()) != set(range(folds)):
        raise ValueError("split assignments do not cover every declared fold")
    ground_truth = {
        key: tuple(boxes) for key, boxes in ground_truth_lists.items()
    }
    return paths, ground_truth, assignments, folds


def run_detector_oof(
    catalog_path: Path,
    split_path: Path,
    baseline_weights: Path,
    output_root: Path,
) -> Path:
    if not baseline_weights.is_file():
        raise FileNotFoundError(f"Baseline weights do not exist: {baseline_weights}")
    output_root = output_root.resolve()
    allowed_output_root = (REPOSITORY_ROOT / "outputs").resolve()
    try:
        output_root.relative_to(allowed_output_root)
    except ValueError as error:
        raise ValueError(f"Output must be under {allowed_output_root}") from error
    paths, ground_truth, assignments, folds = _load_oof_inputs(
        catalog_path, split_path
    )
    missing_images = [str(path) for path in paths.values() if not path.is_file()]
    if missing_images:
        raise FileNotFoundError(f"Catalog image does not exist: {missing_images[0]}")
    predictor = _UltralyticsPredictor(baseline_weights, paths)
    fold_reports: list[DetectorReport] = []
    held_out_latencies: dict[str, float] = {}
    fold_latency_medians: list[float] = []
    for fold in range(folds):
        held_out_keys = tuple(key for key, value in assignments.items() if value == fold)
        validation_fold = (fold + 1) % folds
        validation_keys = tuple(
            key for key, value in assignments.items() if value == validation_fold
        )
        fold_latencies: dict[str, float] = {}
        fold_reports.append(
            evaluate_detector_fold(
                fold=fold,
                validation_keys=validation_keys,
                held_out_keys=held_out_keys,
                ground_truth=ground_truth,
                predict=predictor,
                artifact_path=output_root / f"fold_{fold}_predictions.json",
                latency_records=fold_latencies,
            )
        )
        held_out_latencies.update(fold_latencies)
        fold_latency_medians.append(statistics.median(fold_latencies.values()))
    aggregate = detector_report(fold_reports)
    report_path = output_root / "detector_report.json"
    report_path.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "model": str(baseline_weights.resolve()),
                "aggregation": "paired_fold_mean",
                "ap_confidence_floor": AP_CONFIDENCE_FLOOR,
                "latency_measurement": (
                    "wall_clock_full_predictor_call_per_held_out_image"
                ),
                "folds": [
                    {
                        "fold": index,
                        "metrics": asdict(report),
                        "median_latency_ms": fold_latency_medians[index],
                    }
                    for index, report in enumerate(fold_reports)
                ],
                "metrics": asdict(aggregate),
                "median_latency_ms": (
                    statistics.median(held_out_latencies.values())
                    if held_out_latencies
                    else 0.0
                ),
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    return report_path


def _validate_candidate_cli_inputs(
    catalog_path: Path, split_path: Path, fold_dataset_root: Path
) -> None:
    _, _, assignments, folds = _load_oof_inputs(catalog_path, split_path)
    if folds != 5:
        raise ValueError("Detector candidate OOF requires exactly five folds")
    observed: dict[str, int] = {}
    for fold in range(folds):
        dataset_root = fold_dataset_root / f"fold_{fold}"
        manifest = _candidate_fold_manifest(dataset_root, fold)
        for record in manifest["splits"]["test"]:
            key = str(record["image_key"])
            if key in observed:
                raise ValueError("Detector held-out images must be unique across folds")
            observed[key] = fold
    if observed != assignments:
        raise ValueError("Detector fold manifests do not match the declared split")


def _parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    detector_oof = commands.add_parser("detector-oof")
    detector_oof.add_argument("--catalog", required=True, type=Path)
    detector_oof.add_argument("--split", required=True, type=Path)
    detector_oof.add_argument("--baseline", required=True, type=Path)
    detector_oof.add_argument("--output", required=True, type=Path)
    candidate_oof = commands.add_parser("detector-candidate-oof")
    candidate_oof.add_argument("--catalog", required=True, type=Path)
    candidate_oof.add_argument("--split", required=True, type=Path)
    candidate_oof.add_argument("--datasets", required=True, type=Path)
    candidate_oof.add_argument("--current", required=True, type=Path)
    candidate_oof.add_argument("--output", required=True, type=Path)
    candidate_oof.add_argument("--probe-epochs", type=int)
    classifier_oof = commands.add_parser("classifier-oof")
    classifier_oof.add_argument("--catalog", required=True, type=Path)
    classifier_oof.add_argument("--split", required=True, type=Path)
    classifier_oof.add_argument("--single-root", required=True, type=Path)
    classifier_oof.add_argument("--output", required=True, type=Path)
    classifier_oof.add_argument(
        "--initial-weights", type=Path, default=DEFAULT_CLASSIFIER_INITIAL_WEIGHTS
    )
    classifier_oof.add_argument("--epochs", type=int, default=50)
    classifier_oof.add_argument("--patience", type=int, default=10)
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    args = _parse_args(argv)
    if args.command == "detector-oof":
        report_path = run_detector_oof(
            args.catalog, args.split, args.baseline, args.output
        )
        print(f"report={report_path}")
        return 0
    if args.command == "detector-candidate-oof":
        if not args.current.is_file():
            raise FileNotFoundError(f"Current detector weights do not exist: {args.current}")
        if args.probe_epochs is not None and args.probe_epochs <= 0:
            raise ValueError("probe-epochs must be positive")
        _validate_candidate_cli_inputs(args.catalog, args.split, args.datasets)
        output_root = _guard_output_root(args.output)
        if args.probe_epochs is not None:
            output_root = output_root / f"_probe_{args.probe_epochs}_epoch"
        configs = detector_candidate_matrix(args.current, args.datasets, output_root)
        started = time.perf_counter()
        for config in configs:
            if args.probe_epochs is not None:
                config = replace(config, epochs=args.probe_epochs)
            candidate_started = time.perf_counter()
            report = run_detector_candidate_oof(config)
            elapsed = time.perf_counter() - candidate_started
            print(
                f"candidate={report.name} elapsed_seconds={elapsed:.3f} "
                f"median_latency_ms={report.median_latency_ms:.3f}"
            )
        print(f"total_elapsed_seconds={time.perf_counter() - started:.3f}")
        return 0
    if args.command == "classifier-oof":
        report_path = run_classifier_oof(
            args.catalog,
            args.split,
            args.single_root,
            args.output,
            args.initial_weights,
            args.epochs,
            args.patience,
        )
        print(f"report={report_path}")
        return 0
    raise ValueError(f"Unknown command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
