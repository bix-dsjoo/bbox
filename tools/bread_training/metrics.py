"""Deterministic detector matching, paired fold reports, and adoption gates."""

from __future__ import annotations

import math
import statistics
from dataclasses import dataclass
from decimal import Decimal
from typing import Any, Iterable, Mapping, Sequence


BBox = tuple[float, float, float, float]


@dataclass(frozen=True)
class MatchResult:
    ground_truth_count: int
    prediction_count: int
    matched_pairs: tuple[tuple[int, int], ...]
    matched_ious: tuple[float, ...]
    matched_area_ratios: tuple[float, ...]

    @property
    def matches(self) -> int:
        return len(self.matched_pairs)

    @property
    def misses(self) -> int:
        return self.ground_truth_count - self.matches

    @property
    def false_positives(self) -> int:
        return self.prediction_count - self.matches


@dataclass(frozen=True)
class DetectorReport:
    recall: float
    precision: float
    map50_95: float
    median_iou: float
    median_area_ratio: float


@dataclass(frozen=True)
class GateDecision:
    accepted: bool
    failed_gates: tuple[str, ...]
    checks: Mapping[str, bool]


def _bbox(value: Any) -> BBox:
    if isinstance(value, Mapping):
        value = value["bbox"]
    elif hasattr(value, "bbox"):
        value = value.bbox
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes)):
        raise ValueError("bbox must be a sequence of x, y, width, height")
    if len(value) != 4:
        raise ValueError("bbox must contain four values")
    result = tuple(float(component) for component in value)
    if not all(math.isfinite(component) for component in result):
        raise ValueError("bbox values must be finite")
    if result[2] <= 0 or result[3] <= 0:
        raise ValueError("bbox width and height must be positive")
    return result  # type: ignore[return-value]


def bbox_iou(first: Any, second: Any) -> float:
    ax, ay, aw, ah = _bbox(first)
    bx, by, bw, bh = _bbox(second)
    intersection_width = max(0.0, min(ax + aw, bx + bw) - max(ax, bx))
    intersection_height = max(0.0, min(ay + ah, by + bh) - max(ay, by))
    intersection = intersection_width * intersection_height
    union = aw * ah + bw * bh - intersection
    return intersection / union if union > 0 else 0.0


def match_detections(
    ground_truth: Sequence[Any],
    predictions: Sequence[Any],
    iou_threshold: float = 0.5,
) -> MatchResult:
    """Greedily consume each GT and prediction once, with stable tie breaking."""

    if not 0.0 <= iou_threshold <= 1.0:
        raise ValueError("iou_threshold must be between zero and one")
    gt_boxes = tuple(_bbox(box) for box in ground_truth)
    prediction_boxes = tuple(_bbox(box) for box in predictions)
    adjacency: list[list[tuple[int, float]]] = [[] for _ in gt_boxes]
    for gt_index, gt_box in enumerate(gt_boxes):
        for prediction_index, prediction_box in enumerate(prediction_boxes):
            iou = bbox_iou(gt_box, prediction_box)
            if iou >= iou_threshold:
                adjacency[gt_index].append((prediction_index, iou))
    for edges in adjacency:
        edges.sort(key=lambda edge: (-edge[1], edge[0]))

    prediction_owner: dict[int, int] = {}

    def assign(gt_index: int, seen_predictions: set[int]) -> bool:
        for prediction_index, _ in adjacency[gt_index]:
            if prediction_index in seen_predictions:
                continue
            seen_predictions.add(prediction_index)
            owner = prediction_owner.get(prediction_index)
            if owner is None or assign(owner, seen_predictions):
                prediction_owner[prediction_index] = gt_index
                return True
        return False

    matching_order = sorted(
        range(len(gt_boxes)), key=lambda index: (len(adjacency[index]), index)
    )
    for gt_index in matching_order:
        assign(gt_index, set())

    pairs = sorted((gt_index, prediction_index) for prediction_index, gt_index in prediction_owner.items())
    ious: list[float] = []
    area_ratios: list[float] = []
    for gt_index, prediction_index in pairs:
        ious.append(bbox_iou(gt_boxes[gt_index], prediction_boxes[prediction_index]))
        gt_area = gt_boxes[gt_index][2] * gt_boxes[gt_index][3]
        prediction_area = (
            prediction_boxes[prediction_index][2]
            * prediction_boxes[prediction_index][3]
        )
        area_ratios.append(prediction_area / gt_area)

    return MatchResult(
        ground_truth_count=len(gt_boxes),
        prediction_count=len(prediction_boxes),
        matched_pairs=tuple(pairs),
        matched_ious=tuple(ious),
        matched_area_ratios=tuple(area_ratios),
    )


def detector_report(folds: Iterable[DetectorReport]) -> DetectorReport:
    """Average fold reports equally so baseline/candidate comparisons stay paired."""

    fold_reports = tuple(folds)
    if not fold_reports:
        raise ValueError("at least one detector fold report is required")
    return DetectorReport(
        recall=statistics.fmean(fold.recall for fold in fold_reports),
        precision=statistics.fmean(fold.precision for fold in fold_reports),
        map50_95=statistics.fmean(fold.map50_95 for fold in fold_reports),
        median_iou=statistics.fmean(fold.median_iou for fold in fold_reports),
        median_area_ratio=statistics.fmean(
            fold.median_area_ratio for fold in fold_reports
        ),
    )


def _decimal(value: float) -> Decimal:
    return Decimal(str(value))


def detector_gate(
    baseline: DetectorReport,
    candidate: DetectorReport,
    median_latency_ms: float,
) -> GateDecision:
    checks = {
        "recall_absolute": _decimal(candidate.recall) >= Decimal("0.85"),
        "recall_gain": _decimal(candidate.recall) - _decimal(baseline.recall)
        >= Decimal("0.05"),
        "precision_absolute": _decimal(candidate.precision) >= Decimal("0.97"),
        "precision_drop": _decimal(candidate.precision)
        >= _decimal(baseline.precision) - Decimal("0.01"),
        "map50_95": _decimal(candidate.map50_95) >= _decimal(baseline.map50_95),
        "median_area_ratio": 0.95 <= candidate.median_area_ratio <= 1.05,
        "median_iou": _decimal(candidate.median_iou)
        >= _decimal(baseline.median_iou) - Decimal("0.02"),
        "latency": median_latency_ms <= 1000,
    }
    failed = tuple(name for name, passed in checks.items() if not passed)
    return GateDecision(not failed, failed, checks)
