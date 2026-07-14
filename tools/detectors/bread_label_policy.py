"""Deterministic automatic-label acceptance and review policy."""

from __future__ import annotations

import inspect
import math
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class LabelCandidate:
    label_id: int
    score: float

    def to_json(self) -> dict[str, int | float]:
        return {"labelId": self.label_id, "score": self.score}


@dataclass(frozen=True)
class LabelDecision:
    state: str
    label_id: int | None
    suggested_label_id: int | None
    candidates: tuple[LabelCandidate, ...]
    review_reasons: tuple[str, ...]
    embedding_used: bool

    def to_json(self) -> dict[str, Any]:
        return {
            "state": self.state,
            "labelId": self.label_id,
            "suggestedLabelId": self.suggested_label_id,
            "candidates": [candidate.to_json() for candidate in self.candidates],
            "reviewReasons": list(self.review_reasons),
            "embeddingUsed": self.embedding_used,
        }


@dataclass(frozen=True)
class _Box:
    x: float
    y: float
    width: float
    height: float

    @property
    def right(self) -> float:
        return self.x + self.width

    @property
    def bottom(self) -> float:
        return self.y + self.height

    @property
    def area(self) -> float:
        return self.width * self.height


@dataclass(frozen=True)
class _VerifierResult:
    label_id: int
    score: float
    margin: float


def _field(value: Any, name: str) -> Any:
    if isinstance(value, Mapping):
        try:
            return value[name]
        except KeyError as error:
            raise ValueError(f"box is missing {name}") from error
    try:
        return getattr(value, name)
    except AttributeError as error:
        raise ValueError(f"box is missing {name}") from error


def _normalized_box(value: Any, image_size: Sequence[Any]) -> tuple[_Box, float, float]:
    if not isinstance(image_size, Sequence) or isinstance(image_size, (str, bytes)):
        raise ValueError("image_size must contain width and height")
    if len(image_size) != 2:
        raise ValueError("image_size must contain width and height")
    try:
        image_width, image_height = (float(item) for item in image_size)
        box = _Box(
            x=float(_field(value, "x")),
            y=float(_field(value, "y")),
            width=float(_field(value, "width")),
            height=float(_field(value, "height")),
        )
    except (TypeError, ValueError, OverflowError) as error:
        raise ValueError("box and image dimensions must be finite numbers") from error
    dimensions = (
        image_width,
        image_height,
        box.x,
        box.y,
        box.width,
        box.height,
        box.right,
        box.bottom,
    )
    if not all(math.isfinite(item) for item in dimensions):
        raise ValueError("box and image dimensions must be finite numbers")
    if image_width <= 0 or image_height <= 0:
        raise ValueError("image dimensions must be positive")
    if box.width <= 0 or box.height <= 0:
        raise ValueError("box dimensions must be positive")
    if box.x < 0 or box.y < 0 or box.right > image_width or box.bottom > image_height:
        raise ValueError("box must stay inside the image")
    return box, image_width, image_height


def _manifest_section(manifest: Any, name: str) -> Any:
    if isinstance(manifest, Mapping):
        try:
            return manifest[name]
        except KeyError as error:
            raise ValueError(f"manifest is missing {name}") from error
    try:
        return getattr(manifest, name)
    except AttributeError as error:
        raise ValueError(f"manifest is missing {name}") from error


def _label_id(label: Any) -> int:
    value = label.get("id") if isinstance(label, Mapping) else getattr(label, "id", None)
    if type(value) is not int:
        raise ValueError("manifest labels must have integer IDs")
    return value


def normalized_scores(
    classifier_scores: Any, labels: Sequence[Any]
) -> tuple[LabelCandidate, ...]:
    """Attach ordered manifest IDs to finite scores and sort deterministically."""

    label_ids = tuple(_label_id(label) for label in labels)
    if not label_ids or len(set(label_ids)) != len(label_ids):
        raise ValueError("manifest label IDs must be non-empty and unique")

    if isinstance(classifier_scores, Mapping):
        if set(classifier_scores) != set(label_ids):
            raise ValueError("classifier scores must match manifest label IDs")
        raw_items = tuple((label_id, classifier_scores[label_id]) for label_id in label_ids)
    else:
        try:
            values = tuple(classifier_scores)
        except TypeError as error:
            raise ValueError("classifier scores must be a mapping or sequence") from error
        if len(values) != len(label_ids):
            raise ValueError("classifier scores must match manifest labels")
        if all(isinstance(item, LabelCandidate) for item in values):
            by_id = {item.label_id: item.score for item in values}
            if len(by_id) != len(values) or set(by_id) != set(label_ids):
                raise ValueError("classifier candidates must match manifest label IDs")
            raw_items = tuple((label_id, by_id[label_id]) for label_id in label_ids)
        else:
            raw_items = tuple(zip(label_ids, values))

    candidates: list[LabelCandidate] = []
    for label_id, raw_score in raw_items:
        if type(raw_score) not in (int, float):
            try:
                raw_score = raw_score.item()
            except (AttributeError, TypeError, ValueError) as error:
                raise ValueError("classifier scores must be finite numbers") from error
        if type(raw_score) not in (int, float):
            raise ValueError("classifier scores must be finite numbers")
        score = float(raw_score)
        if not math.isfinite(score) or not 0.0 <= score <= 1.0:
            raise ValueError("classifier scores must be between 0 and 1")
        candidates.append(LabelCandidate(label_id=label_id, score=score))
    candidates.sort(key=lambda item: (-item.score, item.label_id))
    return tuple(candidates)


def _policy_candidates(classifier_scores: Any, manifest: Any) -> tuple[LabelCandidate, ...]:
    labels = _manifest_section(manifest, "labels")
    return normalized_scores(classifier_scores, labels)


def _is_ambiguous(candidates: tuple[LabelCandidate, ...], manifest: Any) -> bool:
    classifier = _manifest_section(manifest, "classifier")
    try:
        confidence_threshold = float(classifier["acceptConfidence"])
        margin_threshold = float(classifier["acceptMargin"])
        conservative = classifier["conservativeClasses"]
    except (KeyError, TypeError, ValueError, OverflowError) as error:
        raise ValueError("manifest classifier policy is invalid") from error
    if (
        not math.isfinite(confidence_threshold)
        or not math.isfinite(margin_threshold)
        or not 0.0 <= confidence_threshold <= 1.0
        or not 0.0 <= margin_threshold <= 1.0
        or not isinstance(conservative, Sequence)
        or isinstance(conservative, (str, bytes))
        or any(type(item) is not int for item in conservative)
    ):
        raise ValueError("manifest classifier policy is invalid")
    top = candidates[0]
    runner_up_score = candidates[1].score if len(candidates) > 1 else 0.0
    return (
        top.score < confidence_threshold
        or top.score - runner_up_score < margin_threshold
        or top.label_id in conservative
    )


def is_ambiguous_scores(classifier_scores: Any, manifest: Any) -> bool:
    return _is_ambiguous(_policy_candidates(classifier_scores, manifest), manifest)


def quality_reasons(
    det_box: Any, image_size: Sequence[Any], quality: Mapping[str, Any]
) -> tuple[str, ...]:
    box, image_width, image_height = _normalized_box(det_box, image_size)
    try:
        min_box_size = float(quality["minBoxSize"])
        edge_margin = float(quality["edgeMarginPx"])
        max_area_ratio = float(quality["maxAreaRatio"])
    except (KeyError, TypeError, ValueError, OverflowError) as error:
        raise ValueError("manifest quality policy is invalid") from error
    thresholds = (min_box_size, edge_margin, max_area_ratio)
    if (
        not all(math.isfinite(item) for item in thresholds)
        or min_box_size < 0
        or edge_margin < 0
        or not 0.0 <= max_area_ratio <= 1.0
    ):
        raise ValueError("manifest quality policy is invalid")

    reasons: list[str] = []
    if box.width < min_box_size or box.height < min_box_size:
        reasons.append("too_small")
    if min(
        box.x,
        box.y,
        image_width - box.right,
        image_height - box.bottom,
    ) <= edge_margin:
        reasons.append("edge_clipped")
    if box.area / (image_width * image_height) > max_area_ratio:
        reasons.append("area_outlier")
    return tuple(reasons)


def _call_verifier(
    verifier: Any, top_label_id: int, candidates: tuple[LabelCandidate, ...]
) -> Any:
    target = getattr(verifier, "verify", verifier)
    if not callable(target):
        raise TypeError("verifier must be callable")
    try:
        signature = inspect.signature(target)
    except (TypeError, ValueError):
        return target(top_label_id, candidates)
    for arguments in ((top_label_id, candidates), (top_label_id,), ()):
        try:
            signature.bind(*arguments)
        except TypeError:
            continue
        return target(*arguments)
    raise TypeError("verifier has an unsupported call signature")


def _verifier_result(value: Any) -> _VerifierResult:
    if isinstance(value, Mapping):
        label_id = value.get("labelId", value.get("label_id"))
        score = value.get("score")
        margin = value.get("margin")
    elif isinstance(value, Sequence) and not isinstance(value, (str, bytes)):
        if len(value) != 3:
            raise ValueError("verifier result must contain label, score, and margin")
        label_id, score, margin = value
    else:
        label_id = getattr(value, "label_id", None)
        score = getattr(value, "score", None)
        margin = getattr(value, "margin", None)
    if type(label_id) is not int or type(score) not in (int, float) or type(margin) not in (int, float):
        raise ValueError("verifier result is invalid")
    normalized = _VerifierResult(label_id, float(score), float(margin))
    if (
        not math.isfinite(normalized.score)
        or not math.isfinite(normalized.margin)
        or not 0.0 <= normalized.score <= 1.0
        or not 0.0 <= normalized.margin <= 1.0
    ):
        raise ValueError("verifier result is invalid")
    return normalized


def _verifier_passes(result: _VerifierResult, top_label_id: int, manifest: Any) -> bool:
    specification = _manifest_section(manifest, "verifier")
    try:
        score_threshold = float(specification["scoreThreshold"])
        margin_threshold = float(specification["marginThreshold"])
    except (KeyError, TypeError, ValueError, OverflowError) as error:
        raise ValueError("manifest verifier policy is invalid") from error
    return (
        result.label_id == top_label_id
        and result.score >= score_threshold
        and result.margin >= margin_threshold
    )


def classify_policy(
    classifier_scores: Any,
    det_box: Any,
    image_size: Sequence[Any],
    manifest: Any,
    verifier: Any = None,
) -> LabelDecision:
    candidates = _policy_candidates(classifier_scores, manifest)
    top_candidates = candidates[:3]
    top_label_id = candidates[0].label_id
    reasons = list(
        quality_reasons(det_box, image_size, _manifest_section(manifest, "quality"))
    )
    ambiguous = _is_ambiguous(candidates, manifest)
    if ambiguous:
        reasons.append("classifier_ambiguous")

    embedding_used = False
    verifier_specification = _manifest_section(manifest, "verifier")
    verifier_enabled = (
        isinstance(verifier_specification, Mapping)
        and verifier_specification.get("kind") != "none"
    )
    if ambiguous and verifier is not None and verifier_enabled:
        try:
            result = _verifier_result(
                _call_verifier(verifier, top_label_id, top_candidates)
            )
            embedding_used = True
            if _verifier_passes(result, top_label_id, manifest):
                reasons.remove("classifier_ambiguous")
        except Exception:
            reasons.append("verifier_failed")

    accepted = not reasons
    return LabelDecision(
        state="accepted" if accepted else "review",
        label_id=top_label_id if accepted else None,
        suggested_label_id=None if accepted else top_label_id,
        candidates=top_candidates,
        review_reasons=tuple(reasons),
        embedding_used=embedding_used,
    )
