from __future__ import annotations

import json
import math
import unittest
from dataclasses import FrozenInstanceError, dataclass

from tools.detectors.bread_label_policy import (
    LabelCandidate,
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

    def test_confident_prediction_is_accepted_with_exact_json_contract(self) -> None:
        decision = classify_policy(
            scores(top1=3, confidence=0.95, margin=0.40),
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
                    {"labelId": 3, "score": 0.95},
                    {"labelId": 1, "score": 0.55},
                    {"labelId": 2, "score": 0.0},
                ],
                "reviewReasons": [],
                "embeddingUsed": False,
            },
        )
        json.dumps(decision.to_json(), allow_nan=False)

    def test_quality_warning_forces_review_even_when_confident(self) -> None:
        decision = classify_policy(
            scores(top1=3, confidence=0.95, margin=0.40),
            Box(2.0, 100.0, 200.0, 100.0),
            (1920, 1080),
            manifest(),
        )

        self.assertEqual(decision.state, "review")
        self.assertIsNone(decision.label_id)
        self.assertEqual(decision.suggested_label_id, 3)
        self.assertIn("edge_clipped", decision.review_reasons)

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
                decision = classify_policy(
                    classifier_scores, normal_box(), (1920, 1080), policy_manifest
                )
                self.assertEqual(decision.state, "review")
                self.assertEqual(decision.review_reasons, ("classifier_ambiguous",))
                self.assertIsNone(decision.label_id)
                self.assertEqual(decision.suggested_label_id, 3)

    def test_passing_verifier_agreement_clears_only_classifier_ambiguity(self) -> None:
        verifier = Verifier({"labelId": 3, "score": 0.90, "margin": 0.20})

        decision = classify_policy(
            scores(top1=3, confidence=0.70, margin=0.02),
            normal_box(),
            (1920, 1080),
            manifest(verifier_kind="torchscript"),
            verifier=verifier,
        )

        self.assertEqual(decision.state, "accepted")
        self.assertEqual(decision.label_id, 3)
        self.assertEqual(decision.review_reasons, ())
        self.assertTrue(decision.embedding_used)
        self.assertEqual(len(verifier.calls), 1)

    def test_verifier_cannot_clear_quality_reasons(self) -> None:
        verifier = Verifier({"labelId": 3, "score": 0.90, "margin": 0.20})

        decision = classify_policy(
            scores(top1=3, confidence=0.70, margin=0.02),
            Box(2.0, 100.0, 200.0, 100.0),
            (1920, 1080),
            manifest(verifier_kind="torchscript"),
            verifier=verifier,
        )

        self.assertEqual(decision.state, "review")
        self.assertEqual(decision.review_reasons, ("edge_clipped",))
        self.assertTrue(decision.embedding_used)

    def test_verifier_disagreement_or_threshold_failure_stays_review(self) -> None:
        cases = (
            {"labelId": 4, "score": 0.90, "margin": 0.20},
            {"labelId": 3, "score": 0.79, "margin": 0.20},
            {"labelId": 3, "score": 0.90, "margin": 0.09},
        )

        for result in cases:
            with self.subTest(result=result):
                decision = classify_policy(
                    scores(top1=3, confidence=0.70, margin=0.02),
                    normal_box(),
                    (1920, 1080),
                    manifest(verifier_kind="torchscript"),
                    verifier=Verifier(result),
                )
                self.assertEqual(decision.state, "review")
                self.assertEqual(decision.review_reasons, ("classifier_ambiguous",))
                self.assertTrue(decision.embedding_used)

    def test_ambiguous_verifier_failure_stays_review(self) -> None:
        decision = classify_policy(
            scores(top1=3, confidence=0.70, margin=0.02),
            normal_box(),
            (1920, 1080),
            manifest(verifier_kind="torchscript"),
            verifier=Verifier(error=RuntimeError("broken verifier")),
        )

        self.assertEqual(decision.state, "review")
        self.assertEqual(
            decision.review_reasons, ("classifier_ambiguous", "verifier_failed")
        )
        self.assertFalse(decision.embedding_used)

    def test_none_or_unneeded_verifier_is_not_invoked(self) -> None:
        verifier = Verifier({"labelId": 3, "score": 1.0, "margin": 1.0})

        confident = classify_policy(
            scores(), normal_box(), (1920, 1080), manifest(), verifier=verifier
        )
        ambiguous_without_verifier = classify_policy(
            scores(confidence=0.70, margin=0.02),
            normal_box(),
            (1920, 1080),
            manifest(),
            verifier=None,
        )

        self.assertEqual(confident.state, "accepted")
        self.assertEqual(ambiguous_without_verifier.state, "review")
        self.assertEqual(verifier.calls, [])
        self.assertFalse(ambiguous_without_verifier.embedding_used)

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


if __name__ == "__main__":
    unittest.main()
