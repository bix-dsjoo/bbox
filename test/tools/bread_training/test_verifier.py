import tempfile
import unittest
from pathlib import Path

from tools.bread_training.verifier import (
    CandidateUnavailable,
    FoldVerifierCandidate,
    MobileNetV3SmallVerifier,
    PrototypeVerifier,
    VerifierMetrics,
    VerifierPrediction,
    VerifierSample,
    YoloPenultimateVerifier,
    choose_verifier,
    cached_default_weight_path,
    evaluate_verifiers,
    verifier_gate,
)


def classifier_only_metrics():
    return VerifierMetrics(
        kind="none",
        ambiguous_accuracy_gain=0.0,
        review_reduction_at_98_precision=0.0,
        auto_precision_drop=0.0,
        p50_ms=0.0,
        p95_ms=0.0,
        supported_class_precision={1: 1.0, 2: 1.0},
    )


class VerifierGateTest(unittest.TestCase):
    def test_verifier_must_meet_accuracy_or_review_reduction_and_latency(self):
        metrics = VerifierMetrics(
            kind="mobilenet_v3_small",
            ambiguous_accuracy_gain=0.031,
            review_reduction_at_98_precision=0.10,
            auto_precision_drop=0.002,
            p50_ms=880,
            p95_ms=1700,
            supported_class_precision={1: 0.98, 2: 0.97},
        )

        decision = choose_verifier(
            {"none": classifier_only_metrics(), "mobilenet_v3_small": metrics}
        )

        self.assertEqual(decision.kind, "mobilenet_v3_small")

    def test_gate_rejects_any_unsafe_class_or_latency(self):
        unsafe = VerifierMetrics(
            kind="yolo_penultimate",
            ambiguous_accuracy_gain=0.04,
            review_reduction_at_98_precision=0.20,
            auto_precision_drop=0.001,
            p50_ms=999,
            p95_ms=2001,
            supported_class_precision={1: 0.949},
        )

        self.assertFalse(verifier_gate(unsafe))

    def test_selection_is_deterministic_on_equal_benefit(self):
        shared = dict(
            ambiguous_accuracy_gain=0.03,
            review_reduction_at_98_precision=0.15,
            auto_precision_drop=0.005,
            p50_ms=900,
            p95_ms=1800,
            supported_class_precision={1: 0.95},
        )
        metrics = {
            "none": classifier_only_metrics(),
            "a": VerifierMetrics(kind="a", **shared),
            "b": VerifierMetrics(kind="b", **shared),
        }

        self.assertEqual(choose_verifier(metrics).kind, "b")


class ConditionalVerifierEvaluationTest(unittest.TestCase):
    def test_candidate_is_invoked_only_for_classifier_ambiguous_samples(self):
        calls = []

        class Candidate:
            kind = "conditional"

            def predict(self, samples):
                calls.extend(sample.sample_id for sample in samples)
                return tuple(
                    VerifierPrediction(
                        sample_id=sample.sample_id,
                        predicted_class=sample.true_class,
                        score=0.99,
                        margin=0.40,
                        latency_ms=10.0,
                    )
                    for sample in samples
                )

        samples = (VerifierSample("white", 1, 1, False, None),) + tuple(
            VerifierSample(f"red-{index}", 1, 2, True, index)
            for index in range(20)
        )

        decision = evaluate_verifiers(samples, (Candidate(),))

        self.assertEqual(calls, [f"red-{index}" for index in range(20)])
        self.assertEqual(decision.metrics.kind, "conditional")
        self.assertEqual(decision.metrics.ambiguous_accuracy_gain, 1.0)

    def test_empty_supported_precision_does_not_bypass_gate(self):
        metrics = VerifierMetrics(
            kind="empty",
            ambiguous_accuracy_gain=1.0,
            review_reduction_at_98_precision=1.0,
            auto_precision_drop=0.0,
            p50_ms=1.0,
            p95_ms=1.0,
            supported_class_precision={},
        )

        self.assertFalse(verifier_gate(metrics))


class ConcretePrototypeVerifierTest(unittest.TestCase):
    def test_fold_router_uses_the_matching_fold_verifier(self):
        calls = []

        class FakeVerifier:
            def __init__(self, fold):
                self.fold = fold

            def fit_group(self, group, sources):
                calls.append(("fit", self.fold, group, tuple(sources)))

            def predict(self, samples):
                calls.append(("predict", self.fold, samples[0].sample_id))
                return (
                    VerifierPrediction(samples[0].sample_id, self.fold + 1, 0.99, 0.5, 1.0),
                )

        candidate = FoldVerifierCandidate(
            "folded", lambda fold: FakeVerifier(fold)
        )
        candidate.fit_group(0, {1: ("a",)})
        candidate.fit_group(1, {1: ("b",)})

        result = candidate.predict(
            (
                VerifierSample("zero", 1, 2, True, None, 0),
                VerifierSample("one", 2, 1, True, None, 1),
            )
        )

        self.assertEqual(tuple(item.predicted_class for item in result), (1, 2))
        self.assertIn(("predict", 0, "zero"), calls)
        self.assertIn(("predict", 1, "one"), calls)

    def test_concrete_verifiers_are_lazy_and_mobilenet_fails_closed(self):
        yolo = YoloPenultimateVerifier(Path("classifier.pt"))
        self.assertEqual(yolo.kind, "yolo_penultimate")

        with tempfile.TemporaryDirectory() as temporary_directory:
            mobilenet = MobileNetV3SmallVerifier(
                hub_directory=Path(temporary_directory)
            )
            with self.assertRaises(CandidateUnavailable):
                mobilenet.fit({1: ("payload",)})

    def test_prototypes_are_normalized_and_ranked_by_cosine_similarity(self):
        vectors = {
            "one-a": (10.0, 0.0),
            "one-b": (2.0, 0.0),
            "two-a": (0.0, 3.0),
            "query": (0.1, 5.0),
        }
        verifier = PrototypeVerifier(
            kind="unit",
            embed_many=lambda payloads: tuple(vectors[item] for item in payloads),
        )
        verifier.fit({1: ("one-a", "one-b"), 2: ("two-a",)})

        result = verifier.predict((VerifierSample("q", 2, 1, True, "query"),))

        self.assertEqual(result[0].predicted_class, 2)
        self.assertGreater(result[0].score, 0.99)
        self.assertGreater(result[0].margin, 0.9)

    def test_missing_default_mobilenet_weight_fails_without_download(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            with self.assertRaisesRegex(CandidateUnavailable, "not cached"):
                cached_default_weight_path(
                    "https://download.pytorch.org/models/mobilenet_v3_small-047dcff4.pth",
                    Path(temporary_directory),
                )


if __name__ == "__main__":
    unittest.main()
