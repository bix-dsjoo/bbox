from __future__ import annotations

import json
import math
import unittest
from dataclasses import FrozenInstanceError, dataclass

from tools.detectors.bread_label_policy import (
    LabelCandidate,
    LabelDecision,
    classify_policy,
    is_ambiguous_scores,
    normalized_scores,
    quality_reasons,
)
from tools.detectors.bread_pipeline_manifest import LabelSpec, PipelineManifest


@dataclass(frozen=True)
class Box:
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


def manifest(
    *,
    accept_confidence: float = 0.90,
    accept_margin: float = 0.20,
    conservative_classes: list[int] | None = None,
    verifier_kind: str = "none",
) -> PipelineManifest:
    verifier = {
        "kind": verifier_kind,
        "file": None if verifier_kind == "none" else "verifier.pt",
        "sha256": None if verifier_kind == "none" else "0" * 64,
        "scoreThreshold": None if verifier_kind == "none" else 0.80,
        "marginThreshold": None if verifier_kind == "none" else 0.10,
    }
    return PipelineManifest(
        schema_version=1,
        pipeline_version="bread-pipeline-v1",
        policy_version="bread-label-policy-v2",
        detector={},
        classifier={
            "acceptConfidence": accept_confidence,
            "acceptMargin": accept_margin,
            "conservativeClasses": conservative_classes or [],
        },
        verifier=verifier,
        quality={
            "minBoxSize": 45,
            "maxAreaRatio": 0.38,
            "edgeMarginPx": 2,
            "duplicateIou": 0.95,
        },
        labels=tuple(LabelSpec(id=label_id, name=f"label-{label_id}") for label_id in range(1, 6)),
    )


def normal_box() -> Box:
    return Box(100.0, 100.0, 200.0, 100.0)


def scores(*, top1: int = 3, confidence: float = 0.95, margin: float = 0.40) -> dict[int, float]:
    runner_up = round(confidence - margin, 12)
    other_ids = [label_id for label_id in range(1, 6) if label_id != top1]
    values = {label_id: 0.0 for label_id in range(1, 6)}
    values[top1] = confidence
    values[other_ids[0]] = runner_up
    return values


class Verifier:
    def __init__(self, result=None, error: Exception | None = None) -> None:
        self.result = result
        self.error = error
        self.calls: list[tuple[int, tuple[LabelCandidate, ...]]] = []

    def verify(self, label_id: int, candidates: tuple[LabelCandidate, ...]):
        self.calls.append((label_id, candidates))
        if self.error is not None:
            raise self.error
        return self.result


class BreadLabelPolicyTest(unittest.TestCase):
    def test_classifier_confidence_maps_to_exact_ui_states(self) -> None:
        cases = (
            (0.50, "unavailable", None, None),
            (0.5001, "review", None, 3),
            (0.9799, "review", None, 3),
            (0.98, "accepted", 3, None),
        )
        for confidence, state, label_id, suggested_id in cases:
            with self.subTest(confidence=confidence):
                decision = classify_policy(
                    scores(top1=3, confidence=confidence, margin=0.40),
                    normal_box(),
                    (1920, 1080),
                    manifest(accept_confidence=0.98),
                )
                self.assertEqual(decision.state, state)
                self.assertEqual(decision.label_id, label_id)
                self.assertEqual(decision.suggested_label_id, suggested_id)

    def test_high_confidence_quality_warning_remains_accepted(self) -> None:
        decision = classify_policy(
            scores(top1=3, confidence=0.98, margin=0.40),
            Box(2.0, 100.0, 200.0, 100.0),
            (1920, 1080),
            manifest(accept_confidence=0.98),
        )

        self.assertEqual(decision.state, "accepted")
        self.assertEqual(decision.label_id, 3)
        self.assertIsNone(decision.suggested_label_id)
        self.assertEqual(decision.review_reasons, ("edge_clipped",))

    def test_normalized_scores_are_immutable_and_candidates_are_deterministic_top_three(self) -> None:
        ordered = normalized_scores(
            {5: 0.1, 2: 0.3, 4: 0.3, 1: 0.2, 3: 0.1}, manifest().labels
        )

        self.assertEqual(
            ordered,
            (
                LabelCandidate(label_id=2, score=0.3),
                LabelCandidate(label_id=4, score=0.3),
                LabelCandidate(label_id=1, score=0.2),
                LabelCandidate(label_id=3, score=0.1),
                LabelCandidate(label_id=5, score=0.1),
            ),
        )
        with self.assertRaises(FrozenInstanceError):
            ordered[0].score = 1.0  # type: ignore[misc]

    def test_boolean_label_ids_cannot_alias_integer_labels(self) -> None:
        boolean_key_scores = {
            True: 0.95,
            2: 0.05,
            3: 0.0,
            4: 0.0,
            5: 0.0,
        }

        with self.assertRaises(ValueError):
            normalized_scores(boolean_key_scores, manifest().labels)
        with self.assertRaises(ValueError):
            LabelCandidate(label_id=True, score=0.95)
        with self.assertRaises(ValueError):
            LabelDecision(
                state="accepted",
                label_id=True,
                suggested_label_id=None,
                candidates=(),
                review_reasons=(),
                embedding_used=False,
            )

    def test_boolean_candidate_id_is_rejected_before_dictionary_aliasing(self) -> None:
        candidates = (
            LabelCandidate.__new__(LabelCandidate),
            LabelCandidate(label_id=2, score=0.05),
            LabelCandidate(label_id=3, score=0.0),
            LabelCandidate(label_id=4, score=0.0),
            LabelCandidate(label_id=5, score=0.0),
        )
        object.__setattr__(candidates[0], "label_id", True)
        object.__setattr__(candidates[0], "score", 0.95)

        with self.assertRaises(ValueError):
            normalized_scores(candidates, manifest().labels)

    def test_confident_prediction_is_accepted_with_exact_json_contract(self) -> None:
        decision = classify_policy(
            scores(top1=3, confidence=0.98, margin=0.40),
            normal_box(),
            (1920, 1080),
            manifest(),
        )

        self.assertEqual(decision.state, "accepted")
        self.assertEqual(decision.label_id, 3)
        self.assertIsNone(decision.suggested_label_id)
        self.assertEqual(decision.review_reasons, ())
        self.assertFalse(decision.embedding_used)
        self.assertEqual(
            decision.to_json(),
            {
                "state": "accepted",
                "labelId": 3,
                "suggestedLabelId": None,
                "candidates": [
                    {"labelId": 3, "score": 0.98},
                    {"labelId": 1, "score": 0.58},
                    {"labelId": 2, "score": 0.0},
                ],
                "reviewReasons": [],
                "embeddingUsed": False,
            },
        )
        json.dumps(decision.to_json(), allow_nan=False)

    def test_quality_reasons_have_stable_order(self) -> None:
        self.assertEqual(
            quality_reasons(Box(0.0, 0.0, 40.0, 40.0), (100, 100), manifest().quality),
            ("too_small", "edge_clipped"),
        )
        self.assertEqual(
            quality_reasons(Box(10.0, 10.0, 80.0, 80.0), (100, 100), manifest().quality),
            ("area_outlier",),
        )

    def test_each_classifier_policy_condition_is_ambiguous(self) -> None:
        cases = (
            (scores(confidence=0.89, margin=0.30), manifest(), "confidence"),
            (scores(confidence=0.95, margin=0.19), manifest(), "margin"),
            (scores(top1=3, confidence=0.95, margin=0.40), manifest(conservative_classes=[3]), "class"),
        )

        for classifier_scores, policy_manifest, name in cases:
            with self.subTest(name=name):
                self.assertTrue(is_ambiguous_scores(classifier_scores, policy_manifest))

    def test_legacy_ambiguity_and_verifier_do_not_override_top_score(self) -> None:
        verifier = Verifier(error=RuntimeError("must not be invoked"))
        cases = (
            (manifest(accept_margin=0.20), "margin"),
            (manifest(conservative_classes=[3]), "class"),
        )

        for policy_manifest, name in cases:
            with self.subTest(name=name):
                classifier_scores = scores(
                    top1=3, confidence=0.98, margin=0.01
                )
                self.assertTrue(
                    is_ambiguous_scores(classifier_scores, policy_manifest)
                )
                decision = classify_policy(
                    classifier_scores,
                    normal_box(),
                    (1920, 1080),
                    policy_manifest,
                    verifier=verifier,
                )
                self.assertEqual(decision.state, "accepted")
                self.assertEqual(decision.label_id, 3)
                self.assertFalse(decision.embedding_used)

        self.assertEqual(verifier.calls, [])

    def test_rejects_invalid_scores_boxes_and_image_sizes(self) -> None:
        cases = (
            ({1: math.nan, 2: 1.0, 3: 0.0, 4: 0.0, 5: 0.0}, normal_box(), (1920, 1080)),
            ({1: -0.1, 2: 1.1, 3: 0.0, 4: 0.0, 5: 0.0}, normal_box(), (1920, 1080)),
            ({1: 1.0}, normal_box(), (1920, 1080)),
            (scores(), Box(0.0, 0.0, math.inf, 10.0), (1920, 1080)),
            (scores(), Box(0.0, 0.0, 0.0, 10.0), (1920, 1080)),
            (scores(), normal_box(), (0, 1080)),
        )

        for classifier_scores, box, image_size in cases:
            with self.subTest(scores=classifier_scores, box=box, image_size=image_size):
                with self.assertRaises(ValueError):
                    classify_policy(classifier_scores, box, image_size, manifest())

    def test_public_inputs_reject_booleans_and_numeric_strings(self) -> None:
        invalid_scores = (
            {1: True, 2: 0.1, 3: 0.9, 4: 0.0, 5: 0.0},
            {1: "0.1", 2: 0.1, 3: 0.8, 4: 0.0, 5: 0.0},
        )
        for classifier_scores in invalid_scores:
            with self.subTest(classifier_scores=classifier_scores):
                with self.assertRaises(ValueError):
                    classify_policy(
                        classifier_scores, normal_box(), (1920, 1080), manifest()
                    )

        invalid_geometry = (
            (Box(True, 100.0, 200.0, 100.0), (1920, 1080)),
            (Box("100", 100.0, 200.0, 100.0), (1920, 1080)),  # type: ignore[arg-type]
            (normal_box(), (True, 1080)),
            (normal_box(), ("1920", 1080)),
            (normal_box(), (math.inf, 1080)),
        )
        for box, image_size in invalid_geometry:
            with self.subTest(box=box, image_size=image_size):
                with self.assertRaises(ValueError):
                    classify_policy(scores(), box, image_size, manifest())

    def test_extreme_integers_fail_as_validation_errors(self) -> None:
        enormous = 10**400

        with self.assertRaises(ValueError):
            LabelCandidate(label_id=1, score=enormous)
        with self.assertRaises(ValueError):
            normalized_scores(
                {1: enormous, 2: 0.1, 3: 0.9, 4: 0.0, 5: 0.0},
                manifest().labels,
            )
        with self.assertRaises(ValueError):
            classify_policy(
                scores(), Box(enormous, 0, 10, 10), (1920, 1080), manifest()
            )

    def test_public_policy_thresholds_reject_booleans_and_numeric_strings(self) -> None:
        for field, value in (
            ("acceptConfidence", True),
            ("acceptMargin", "0.2"),
            ("acceptConfidence", math.nan),
        ):
            policy_manifest = manifest()
            policy_manifest.classifier[field] = value
            with self.subTest(section="classifier", field=field, value=value):
                with self.assertRaises(ValueError):
                    classify_policy(
                        scores(), normal_box(), (1920, 1080), policy_manifest
                    )

        for field, value in (
            ("minBoxSize", True),
            ("edgeMarginPx", "2"),
            ("maxAreaRatio", "0.38"),
            ("edgeMarginPx", math.inf),
        ):
            policy_manifest = manifest()
            policy_manifest.quality[field] = value
            with self.subTest(section="quality", field=field, value=value):
                with self.assertRaises(ValueError):
                    classify_policy(
                        scores(), normal_box(), (1920, 1080), policy_manifest
                    )

    def test_invalid_verifier_threshold_does_not_override_confidence_state(self) -> None:
        for field, value in (("scoreThreshold", True), ("marginThreshold", math.nan)):
            policy_manifest = manifest(verifier_kind="torchscript")
            policy_manifest.verifier[field] = value

            decision = classify_policy(
                scores(confidence=0.70, margin=0.02),
                normal_box(),
                (1920, 1080),
                policy_manifest,
                verifier=Verifier({"labelId": 3, "score": 0.90, "margin": 0.20}),
            )

            with self.subTest(field=field, value=value):
                self.assertEqual(decision.state, "review")
                self.assertEqual(
                    decision.review_reasons, ("classifier_confidence_review",)
                )
                self.assertFalse(decision.embedding_used)


if __name__ == "__main__":
    unittest.main()
