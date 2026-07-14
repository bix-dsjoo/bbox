"""Train detector folds and run leakage-safe, baseline-only OOF evaluation."""

from __future__ import annotations

import argparse
import json
import statistics
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence

from tools.bread_training.metrics import (
    BBox,
    DetectorReport,
    detector_report,
    match_detections,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_THRESHOLD_CANDIDATES = tuple(value / 100 for value in range(5, 100, 5))


@dataclass(frozen=True)
class DetectorTrainConfig:
    initial_weights: Path
    dataset_yaml: Path
    seed: int
    output_root: Path
    run_name: str


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


def train_detector_fold(config: DetectorTrainConfig) -> Path:
    YOLO = _yolo_class()
    model = YOLO(str(config.initial_weights))
    result = model.train(
        data=str(config.dataset_yaml),
        imgsz=640,
        device="cpu",
        seed=config.seed,
        deterministic=True,
        project=str(config.output_root),
        name=config.run_name,
    )
    return Path(result.save_dir) / "weights" / "best.pt"


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
    ground_truth: Mapping[str, Sequence[BBox]], predictions: PredictionMap
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
    map50_95 = statistics.fmean(
        _average_precision(ground_truth, predictions, threshold / 100)
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
) -> DetectorReport:
    """Select on train-side data, then run held-out inference with a frozen value."""

    validation_keys = tuple(sorted(validation_keys))
    held_out_keys = tuple(sorted(held_out_keys))
    if set(validation_keys) & set(held_out_keys):
        raise ValueError("train-side validation and held-out image keys must be disjoint")
    raw_validation_predictions = predict(validation_keys, 0.0)
    threshold = select_confidence_threshold(
        {key: ground_truth.get(key, ()) for key in validation_keys},
        raw_validation_predictions,
        threshold_candidates,
    )
    held_out_predictions = predict(held_out_keys, threshold)
    held_out_predictions = _filtered_predictions(held_out_predictions, threshold)
    held_out_ground_truth = {
        key: tuple(ground_truth.get(key, ())) for key in held_out_keys
    }
    report = evaluate_predictions(held_out_ground_truth, held_out_predictions)
    payload = {
        "schema_version": 1,
        "fold": fold,
        "confidence_threshold": threshold,
        "threshold_selected_from": list(validation_keys),
        "metrics": asdict(report),
        "images": [
            {
                "image_key": image_key,
                "ground_truth": [list(box) for box in held_out_ground_truth[image_key]],
                "predictions": [
                    _prediction_json(prediction)
                    for prediction in held_out_predictions.get(image_key, ())
                ],
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
    def __init__(self, weights: Path, paths_by_key: Mapping[str, Path]):
        YOLO = _yolo_class()
        self._model = YOLO(str(weights))
        self._paths_by_key = paths_by_key
        self.latencies_ms: list[float] = []

    def __call__(
        self, image_keys: Sequence[str], confidence: float
    ) -> dict[str, tuple[Prediction, ...]]:
        if not image_keys:
            return {}
        paths = [str(self._paths_by_key[key]) for key in image_keys]
        started = time.perf_counter()
        results = self._model.predict(
            source=paths,
            conf=max(confidence, 0.001),
            imgsz=640,
            device="cpu",
            verbose=False,
            stream=False,
        )
        elapsed_ms = (time.perf_counter() - started) * 1000
        if len(results) != len(image_keys):
            raise RuntimeError("Ultralytics returned a different number of results")
        predictions: dict[str, tuple[Prediction, ...]] = {}
        fallback_latency = elapsed_ms / len(image_keys)
        for image_key, result in zip(image_keys, results):
            speed = getattr(result, "speed", {}) or {}
            self.latencies_ms.append(float(speed.get("inference", fallback_latency)))
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
    for fold in range(folds):
        held_out_keys = tuple(key for key, value in assignments.items() if value == fold)
        validation_fold = (fold + 1) % folds
        validation_keys = tuple(
            key for key, value in assignments.items() if value == validation_fold
        )
        fold_reports.append(
            evaluate_detector_fold(
                fold=fold,
                validation_keys=validation_keys,
                held_out_keys=held_out_keys,
                ground_truth=ground_truth,
                predict=predictor,
                artifact_path=output_root / f"fold_{fold}_predictions.json",
            )
        )
    aggregate = detector_report(fold_reports)
    report_path = output_root / "detector_report.json"
    report_path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "model": str(baseline_weights.resolve()),
                "aggregation": "paired_fold_mean",
                "folds": [
                    {"fold": index, "metrics": asdict(report)}
                    for index, report in enumerate(fold_reports)
                ],
                "metrics": asdict(aggregate),
                "median_latency_ms": (
                    statistics.median(predictor.latencies_ms)
                    if predictor.latencies_ms
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


def _parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    detector_oof = commands.add_parser("detector-oof")
    detector_oof.add_argument("--catalog", required=True, type=Path)
    detector_oof.add_argument("--split", required=True, type=Path)
    detector_oof.add_argument("--baseline", required=True, type=Path)
    detector_oof.add_argument("--output", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    args = _parse_args(argv)
    if args.command == "detector-oof":
        report_path = run_detector_oof(
            args.catalog, args.split, args.baseline, args.output
        )
        print(f"report={report_path}")
        return 0
    raise ValueError(f"Unknown command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
