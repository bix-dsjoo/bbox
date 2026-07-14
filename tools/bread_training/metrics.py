"""Deterministic detector matching, paired fold reports, and adoption gates."""

from __future__ import annotations

import math
import statistics
from collections import Counter
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


@dataclass(frozen=True)
class ClassificationPrediction:
    sample_id: str
    true_class: int
    predicted_class: int
    confidence: float
    margin: float
    top3: tuple[int, ...] = ()


@dataclass(frozen=True)
class LabelPolicy:
    version: str
    confidence: float
    margin: float
    conservative_classes: tuple[int, ...]


def _classification_prediction(value: Any) -> ClassificationPrediction:
    if isinstance(value, ClassificationPrediction):
        prediction = value
    elif isinstance(value, Mapping):
        prediction = ClassificationPrediction(
            sample_id=str(value.get("sample_id", "")),
            true_class=int(value["true_class"]),
            predicted_class=int(value["predicted_class"]),
            confidence=float(value["confidence"]),
            margin=float(value["margin"]),
            top3=tuple(int(item) for item in value.get("top3", ())),
        )
    else:
        prediction = ClassificationPrediction(
            sample_id=str(getattr(value, "sample_id", "")),
            true_class=int(value.true_class),
            predicted_class=int(value.predicted_class),
            confidence=float(value.confidence),
            margin=float(value.margin),
            top3=tuple(int(item) for item in getattr(value, "top3", ())),
        )
    if prediction.true_class <= 0 or prediction.predicted_class <= 0:
        raise ValueError("class identifiers must be positive integers")
    if not 0.0 <= prediction.confidence <= 1.0:
        raise ValueError("confidence must be between zero and one")
    if not 0.0 <= prediction.margin <= 1.0:
        raise ValueError("margin must be between zero and one")
    return prediction


def classification_precision(predictions: Iterable[Any]) -> float:
    values = tuple(_classification_prediction(item) for item in predictions)
    if not values:
        return 1.0
    return sum(item.true_class == item.predicted_class for item in values) / len(values)


def is_ambiguous(confidence: float, margin: float, policy: LabelPolicy) -> bool:
    return confidence < policy.confidence or margin < policy.margin


def apply_label_policy(
    predictions: Iterable[Any], policy: LabelPolicy
) -> tuple[ClassificationPrediction, ...]:
    conservative = set(policy.conservative_classes)
    return tuple(
        prediction
        for prediction in (
            _classification_prediction(item) for item in predictions
        )
        if prediction.predicted_class not in conservative
        and not is_ambiguous(prediction.confidence, prediction.margin, policy)
    )


def calibration_threshold_candidates(
    values: Iterable[float],
) -> tuple[float, ...]:
    return tuple(sorted({0.0, *(float(value) for value in values)}))


def calibrate_auto_label(
    predictions: Iterable[Any], min_precision: float = 0.94
) -> LabelPolicy:
    """Maximize OOF auto-label coverage subject to precision safety gates."""

    if not 0.0 < min_precision <= 1.0:
        raise ValueError("min_precision must be greater than zero and at most one")
    values = tuple(_classification_prediction(item) for item in predictions)
    support = Counter(item.true_class for item in values)
    observed_classes = {
        class_id
        for item in values
        for class_id in (item.true_class, item.predicted_class)
    }
    conservative = tuple(
        sorted(class_id for class_id in observed_classes if support[class_id] < 20)
    )
    if not values:
        return LabelPolicy("bread-label-policy-v2", 1.0, 1.0, conservative)

    confidence_candidates = calibration_threshold_candidates(
        item.confidence for item in values
    )
    margin_candidates = calibration_threshold_candidates(item.margin for item in values)
    conservative_set = set(conservative)
    by_margin = tuple(
        sorted(
            (
                item
                for item in values
                if item.predicted_class not in conservative_set
            ),
            key=lambda item: (-item.margin, item.sample_id),
        )
    )
    supported_classes = tuple(
        class_id for class_id, class_support in support.items() if class_support >= 20
    )
    best: tuple[int, float, float] | None = None
    for confidence in confidence_candidates:
        accepted_count = 0
        correct_count = 0
        class_accepted = Counter()
        class_correct = Counter()
        cursor = 0
        for margin in reversed(margin_candidates):
            while cursor < len(by_margin) and by_margin[cursor].margin >= margin:
                item = by_margin[cursor]
                cursor += 1
                if item.confidence < confidence:
                    continue
                accepted_count += 1
                class_accepted[item.predicted_class] += 1
                if item.true_class == item.predicted_class:
                    correct_count += 1
                    class_correct[item.predicted_class] += 1
            if not accepted_count or correct_count / accepted_count < min_precision:
                continue
            class_safe = all(
                not class_accepted[class_id]
                or class_correct[class_id] / class_accepted[class_id] >= 0.95
                for class_id in supported_classes
            )
            if not class_safe:
                continue
            candidate = (accepted_count, -confidence, -margin)
            if best is None or candidate > best:
                best = candidate

    if best is None:
        return LabelPolicy(
            "bread-label-policy-v2",
            math.nextafter(max(item.confidence for item in values), math.inf),
            math.nextafter(max(item.margin for item in values), math.inf),
            conservative,
        )
    return LabelPolicy(
        "bread-label-policy-v2", -best[1], -best[2], conservative
    )


def derive_deployment_policy(fold_policies: Iterable[LabelPolicy]) -> LabelPolicy:
    policies = tuple(fold_policies)
    if len(policies) != 5:
        raise ValueError("exactly five validation-derived policies are required")
    return LabelPolicy(
        version="bread-label-policy-v2",
        confidence=float(statistics.median(item.confidence for item in policies)),
        margin=float(statistics.median(item.margin for item in policies)),
        conservative_classes=tuple(
            sorted(
                set().union(
                    *(item.conservative_classes for item in policies)
                )
            )
        ),
    )


def deployment_policy_report(
    predictions: Iterable[Any], policy: LabelPolicy
) -> dict[str, Any]:
    values = tuple(_classification_prediction(item) for item in predictions)
    accepted = apply_label_policy(values, policy)
    coverage = len(accepted) / len(values) if values else 0.0
    return {
        "precision": classification_precision(accepted),
        "coverage": coverage,
        "redReviewRate": 1.0 - coverage,
        "acceptedSampleIds": [item.sample_id for item in accepted],
    }


def _expected_calibration_error(
    predictions: Sequence[ClassificationPrediction], bins: int = 10
) -> float:
    if not predictions:
        return 0.0
    error = 0.0
    for index in range(bins):
        lower = index / bins
        upper = (index + 1) / bins
        bucket = tuple(
            item
            for item in predictions
            if lower <= item.confidence <= upper
            and (index == bins - 1 or item.confidence < upper)
        )
        if not bucket:
            continue
        accuracy = statistics.fmean(
            item.true_class == item.predicted_class for item in bucket
        )
        confidence = statistics.fmean(item.confidence for item in bucket)
        error += len(bucket) / len(predictions) * abs(accuracy - confidence)
    return error


def classifier_report(
    predictions: Iterable[Any], policy: LabelPolicy
) -> dict[str, Any]:
    values = tuple(_classification_prediction(item) for item in predictions)
    classes = sorted(
        {item.true_class for item in values}
        | {item.predicted_class for item in values}
    )
    per_class: dict[str, dict[str, float | int]] = {}
    f1_values: list[float] = []
    for class_id in classes:
        true_positive = sum(
            item.true_class == class_id and item.predicted_class == class_id
            for item in values
        )
        predicted_count = sum(item.predicted_class == class_id for item in values)
        support = sum(item.true_class == class_id for item in values)
        precision = true_positive / predicted_count if predicted_count else 0.0
        recall = true_positive / support if support else 0.0
        f1 = (
            2 * precision * recall / (precision + recall)
            if precision + recall
            else 0.0
        )
        f1_values.append(f1)
        per_class[str(class_id)] = {
            "support": support,
            "precision": precision,
            "recall": recall,
            "f1": f1,
        }
    accepted = apply_label_policy(values, policy)
    total = len(values)
    return {
        "top1_accuracy": classification_precision(values) if values else 0.0,
        "macro_f1": statistics.fmean(f1_values) if f1_values else 0.0,
        "top3_accuracy": (
            statistics.fmean(
                item.true_class
                in (item.top3 if item.top3 else (item.predicted_class,))
                for item in values
            )
            if values
            else 0.0
        ),
        "expected_calibration_error": _expected_calibration_error(values),
        "white_auto_precision": (
            classification_precision(accepted) if accepted else 1.0
        ),
        "white_coverage": len(accepted) / total if total else 0.0,
        "red_review_rate": 1.0 - len(accepted) / total if total else 0.0,
        "per_class": per_class,
    }


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
