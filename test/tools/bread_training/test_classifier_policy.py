import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.bread_training.metrics import (
    ClassificationPrediction,
    apply_label_policy,
    calibration_threshold_candidates,
    calibrate_auto_label,
    classifier_report,
    classification_precision,
    fail_closed_label_policy,
    is_ambiguous,
)
from tools.bread_training.train import (
    ClassifierTrainConfig,
    DEFAULT_CLASSIFIER_INITIAL_WEIGHTS,
    _parse_args,
    build_classifier_fold_manifest,
    classifier_class_map,
    train_classifier_fold,
)


def prediction(
    sample_id,
    true_class,
    predicted_class,
    confidence,
    margin,
):
    return ClassificationPrediction(
        sample_id=sample_id,
        true_class=true_class,
        predicted_class=predicted_class,
        confidence=confidence,
        margin=margin,
        top3=(predicted_class,),
    )


class ClassifierPolicyTest(unittest.TestCase):
    def test_large_calibration_grid_is_bounded_and_keeps_endpoints(self):
        values = tuple(index / 2000 for index in range(2001))

        candidates = calibration_threshold_candidates(values)

        self.assertLessEqual(len(candidates), 512)
        self.assertEqual(candidates[0], 0.0)
        self.assertEqual(candidates[-1], 1.0)

    def test_calibration_chooses_highest_coverage_at_required_precision(self):
        predictions = []
        for index in range(49):
            predictions.append(prediction(f"good-{index}", 1, 1, 0.90, 0.40))
        predictions.extend(
            (
                prediction("high-wrong", 2, 1, 0.91, 0.39),
                prediction("low-good", 2, 2, 0.70, 0.20),
                prediction("low-wrong", 3, 2, 0.69, 0.19),
            )
        )

        policy = calibrate_auto_label(predictions, min_precision=0.98)
        accepted = apply_label_policy(predictions, policy)

        self.assertGreaterEqual(classification_precision(accepted), 0.98)
        self.assertEqual(len(accepted), 50)
        self.assertEqual(policy.version, "bread-label-policy-v1")

    def test_sparse_class_stays_review_required(self):
        predictions = [
            prediction(f"sparse-{index}", 11, 11, 0.99, 0.90)
            for index in range(8)
        ]

        policy = calibrate_auto_label(predictions, min_precision=0.98)

        self.assertIn(11, policy.conservative_classes)
        self.assertEqual(apply_label_policy(predictions, policy), ())

    def test_class_with_predictions_but_no_true_support_stays_review_required(self):
        predictions = [
            prediction(f"supported-{index}", 1, 1, 0.99, 0.90)
            for index in range(20)
        ]
        predictions.append(prediction("unsupported", 1, 2, 0.99, 0.90))

        policy = calibrate_auto_label(predictions, min_precision=0.90)

        self.assertIn(2, policy.conservative_classes)

    def test_oof_precision_failure_forces_every_class_to_review(self):
        predictions = (
            prediction("correct", 1, 1, 0.99, 0.90),
            prediction("wrong", 2, 1, 0.99, 0.90),
        )
        policy = calibrate_auto_label((predictions[0],), min_precision=0.98)

        safe = fail_closed_label_policy(policy, predictions, (1, 2), 0.98)

        self.assertEqual(safe.conservative_classes, (1, 2))
        self.assertEqual(apply_label_policy(predictions, safe), ())

    def test_supported_class_must_retain_95_percent_precision(self):
        predictions = [
            prediction(f"class-1-{index}", 1, 1, 0.95, 0.50)
            for index in range(20)
        ]
        predictions.extend(
            prediction(f"class-2-{index}", 2, 2, 0.90, 0.40)
            for index in range(19)
        )
        predictions.append(prediction("class-2-wrong", 3, 2, 0.90, 0.40))

        policy = calibrate_auto_label(predictions, min_precision=0.95)
        accepted = apply_label_policy(predictions, policy)

        self.assertEqual({item.predicted_class for item in accepted}, {1})

    def test_ambiguity_uses_strict_threshold_boundaries(self):
        predictions = [
            prediction(f"sample-{index}", 1, 1, 0.90, 0.30)
            for index in range(20)
        ]
        policy = calibrate_auto_label(predictions)

        self.assertFalse(is_ambiguous(policy.confidence, policy.margin, policy))
        self.assertTrue(is_ambiguous(policy.confidence - 0.001, policy.margin, policy))
        self.assertTrue(is_ambiguous(policy.confidence, policy.margin - 0.001, policy))

    def test_report_contains_accuracy_calibration_and_white_red_rates(self):
        predictions = [
            prediction(f"one-{index}", 1, 1, 0.95, 0.50)
            for index in range(20)
        ]
        predictions.extend(
            prediction(f"two-{index}", 2, 2, 0.90, 0.50)
            for index in range(19)
        )
        predictions.append(prediction("wrong", 2, 1, 0.99, 0.10))
        policy = calibrate_auto_label(predictions)

        report = classifier_report(predictions, policy)

        self.assertAlmostEqual(report["top1_accuracy"], 39 / 40)
        self.assertEqual(report["top3_accuracy"], 39 / 40)
        self.assertGreater(report["macro_f1"], 0.97)
        self.assertIn("expected_calibration_error", report)
        self.assertEqual(report["white_auto_precision"], 1.0)
        self.assertAlmostEqual(report["white_coverage"], 39 / 40)
        self.assertAlmostEqual(report["red_review_rate"], 1 / 40)
        self.assertEqual(report["per_class"]["1"]["support"], 20)


class ClassifierTrainingAdapterTest(unittest.TestCase):
    def test_default_classifier_oof_uses_generic_20_class_training_not_baseline(self):
        args = _parse_args(
            (
                "classifier-oof",
                "--catalog",
                "catalog.json",
                "--split",
                "split.json",
                "--single-root",
                "raw",
                "--output",
                "outputs/model_selection/classifier",
            )
        )

        self.assertEqual(DEFAULT_CLASSIFIER_INITIAL_WEIGHTS, Path("yolov8n-cls.pt"))
        self.assertEqual(args.initial_weights, DEFAULT_CLASSIFIER_INITIAL_WEIGHTS)
        self.assertFalse(hasattr(args, "baseline"))

    def test_fold_manifest_excludes_heldout_mixed_keys_from_train_and_validation(self):
        catalog = {
            "images": [
                {"key": "mixed-held", "source_kind": "mixed_scene"},
                {"key": "mixed-val", "source_kind": "mixed_scene"},
                {"key": "mixed-train", "source_kind": "mixed_scene"},
                {"key": "single-held", "source_kind": "single_bread"},
                {"key": "single-val", "source_kind": "single_bread"},
                {"key": "single-train", "source_kind": "single_bread"},
            ]
        }
        split = {
            "folds": 5,
            "mixed_assignments": {
                "mixed-held": 0,
                "mixed-val": 1,
                "mixed-train": 2,
            },
            "single_product_assignments": {
                "single-held": 0,
                "single-val": 1,
                "single-train": 2,
            },
        }

        manifest = build_classifier_fold_manifest(catalog, split, fold=0)

        self.assertEqual(manifest.held_out_mixed_keys, ("mixed-held",))
        self.assertEqual(manifest.validation_mixed_keys, ("mixed-val",))
        self.assertEqual(manifest.training_mixed_keys, ("mixed-train",))
        self.assertNotIn("mixed-held", manifest.training_mixed_keys)
        self.assertNotIn("mixed-held", manifest.validation_mixed_keys)
        self.assertEqual(manifest.validation_single_keys, ("single-val",))
        self.assertEqual(manifest.training_single_keys, ("single-train",))

    def test_classifier_names_map_to_canonical_ids_and_expose_missing_class(self):
        labels = (
            {"id": 1, "name": "Walnut Donut"},
            {"id": 4, "name": "Scon"},
            {"id": 8, "name": "Almond Scon"},
            {"id": 18, "name": "Mini Bread"},
        )

        mapping, missing = classifier_class_map(
            {0: "walnut_donut", 1: "scone", 2: "almond_scone"}, labels
        )

        self.assertEqual(mapping, {0: 1, 1: 4, 2: 8})
        self.assertEqual(missing, (18,))

    def test_train_adapter_imports_ultralytics_lazily_and_is_deterministic(self):
        calls = []

        class FakeYOLO:
            def __init__(self, weights):
                calls.append(("init", weights))

            def train(self, **kwargs):
                calls.append(("train", kwargs))
                return types.SimpleNamespace(
                    save_dir=str(Path(kwargs["project"]) / kwargs["name"])
                )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            config = ClassifierTrainConfig(
                initial_weights=root / "classifier.pt",
                dataset_dir=root / "dataset",
                seed=20260714,
                output_root=root / "runs",
                run_name="fold-3",
                epochs=7,
                patience=3,
            )
            with patch.dict(sys.modules, {"ultralytics": types.SimpleNamespace(YOLO=FakeYOLO)}):
                best = train_classifier_fold(config)

        self.assertEqual(calls[0], ("init", str(config.initial_weights)))
        self.assertEqual(
            calls[1],
            (
                "train",
                {
                    "data": str(config.dataset_dir),
                    "imgsz": 224,
                    "device": 0,
                    "seed": 20260714,
                    "deterministic": True,
                    "epochs": 7,
                    "patience": 3,
                    "batch": 64,
                    "workers": 0,
                    "project": str(config.output_root),
                    "name": "fold-3",
                    "exist_ok": True,
                },
            ),
        )
        self.assertEqual(best, config.output_root / "fold-3" / "weights" / "best.pt")


if __name__ == "__main__":
    unittest.main()
