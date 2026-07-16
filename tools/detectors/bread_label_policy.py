"""Deterministic automatic-label acceptance and review policy."""

from __future__ import annotations

import inspect
import math
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any


UNLABELED_CONFIDENCE_MAX = 0.50
AUTO_LABEL_CONFIDENCE_MIN = 0.98


@dataclass(frozen=True)
class LabelCandidate:
    label_id: int
    score: float

    def __post_init__(self) -> None:
        if type(self.label_id) is not int:
            raise ValueError("candidate label ID must be an integer")
        _exact_number(self.score, "candidate score", minimum=0.0, maximum=1.0)

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

    def __post_init__(self) -> None:
        if self.label_id is not None and type(self.label_id) is not int:
            raise ValueError("decision label ID must be an integer or null")
        if (
            self.suggested_label_id is not None
            and type(self.suggested_label_id) is not int
        ):
            raise ValueError("suggested label ID must be an integer or null")

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


def _exact_number(
    value: Any,
    name: str,
    *,
    minimum: float | None = None,
    maximum: float | None = None,
) -> float:
    if type(value) not in (int, float):
        raise ValueError(f"{name} must be an integer or float")
    try:
        number = float(value)
    except OverflowError as error:
        raise ValueError(f"{name} must be finite") from error
    if not math.isfinite(number):
        raise ValueError(f"{name} must be finite")
    if minimum is not None and number < minimum:
        raise ValueError(f"{name} must be at least {minimum}")
    if maximum is not None and number > maximum:
        raise ValueError(f"{name} must be at most {maximum}")
    return number


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
        image_width = _exact_number(image_size[0], "image width")
        image_height = _exact_number(image_size[1], "image height")
        box = _Box(
            x=_exact_number(_field(value, "x"), "box x"),
            y=_exact_number(_field(value, "y"), "box y"),
            width=_exact_number(_field(value, "width"), "box width"),
            height=_exact_number(_field(value, "height"), "box height"),
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
        if any(type(key) is not int for key in classifier_scores):
            raise ValueError("classifier score label IDs must be integers")
        if set(classifier_scores) != set(label_ids):
            raise ValueError("classifier scores must match manifest label IDs")
        raw_items = tuple((label_id, classifier_scores[label_id]) for label_id in label_ids)
    else:
        if hasattr(classifier_scores, "tolist"):
            classifier_scores = classifier_scores.tolist()
        try:
            values = tuple(classifier_scores)
        except TypeError as error:
            raise ValueError("classifier scores must be a mapping or sequence") from error
        if len(values) != len(label_ids):
            raise ValueError("classifier scores must match manifest labels")
        if all(isinstance(item, LabelCandidate) for item in values):
            if any(type(item.label_id) is not int for item in values):
                raise ValueError("classifier candidate label IDs must be integers")
            by_id = {item.label_id: item.score for item in values}
            if len(by_id) != len(values) or set(by_id) != set(label_ids):
                raise ValueError("classifier candidates must match manifest label IDs")
            raw_items = tuple((label_id, by_id[label_id]) for label_id in label_ids)
        else:
            raw_items = tuple(zip(label_ids, values))

    candidates: list[LabelCandidate] = []
    for label_id, raw_score in raw_items:
        score = _exact_number(
            raw_score, "classifier score", minimum=0.0, maximum=1.0
        )
        candidates.append(LabelCandidate(label_id=label_id, score=score))
    candidates.sort(key=lambda item: (-item.score, item.label_id))
    return tuple(candidates)


def _policy_candidates(classifier_scores: Any, manifest: Any) -> tuple[LabelCandidate, ...]:
    labels = _manifest_section(manifest, "labels")
    return normalized_scores(classifier_scores, labels)


def _is_ambiguous(candidates: tuple[LabelCandidate, ...], manifest: Any) -> bool:
    classifier = _manifest_section(manifest, "classifier")
    try:
        confidence_threshold = _exact_number(
            classifier["acceptConfidence"],
            "acceptConfidence",
            minimum=0.0,
            maximum=1.0,
        )
        margin_threshold = _exact_number(
            classifier["acceptMargin"],
            "acceptMargin",
            minimum=0.0,
            maximum=1.0,
        )
        conservative = classifier["conservativeClasses"]
    except (KeyError, TypeError, ValueError, OverflowError) as error:
        raise ValueError("manifest classifier policy is invalid") from error
    if (
        not isinstance(conservative, Sequence)
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
        min_box_size = _exact_number(
            quality["minBoxSize"], "minBoxSize", minimum=0.0
        )
        edge_margin = _exact_number(
            quality["edgeMarginPx"], "edgeMarginPx", minimum=0.0
        )
        max_area_ratio = _exact_number(
            quality["maxAreaRatio"],
            "maxAreaRatio",
            minimum=0.0,
            maximum=1.0,
        )
    except (KeyError, TypeError, ValueError, OverflowError) as error:
        raise ValueError("manifest quality policy is invalid") from error
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
        score_threshold = _exact_number(
            specification["scoreThreshold"],
            "verifier scoreThreshold",
            minimum=0.0,
            maximum=1.0,
        )
        margin_threshold = _exact_number(
            specification["marginThreshold"],
            "verifier marginThreshold",
            minimum=0.0,
            maximum=1.0,
        )
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
    _is_ambiguous(candidates, manifest)
    diagnostics = quality_reasons(
        det_box, image_size, _manifest_section(manifest, "quality")
    )
    top = candidates[0]
    if top.score <= UNLABELED_CONFIDENCE_MAX:
        return LabelDecision(
            state="unavailable",
            label_id=None,
            suggested_label_id=None,
            candidates=top_candidates,
            review_reasons=("classifier_low_confidence",),
            embedding_used=False,
        )
    if top.score < AUTO_LABEL_CONFIDENCE_MIN:
        return LabelDecision(
            state="review",
            label_id=None,
            suggested_label_id=top.label_id,
            candidates=top_candidates,
            review_reasons=("classifier_confidence_review",),
            embedding_used=False,
        )
    return LabelDecision(
        state="accepted",
        label_id=top.label_id,
        suggested_label_id=None,
        candidates=top_candidates,
        review_reasons=diagnostics,
        embedding_used=False,
    )
