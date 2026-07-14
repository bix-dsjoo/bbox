import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.bread_training.train import (
    AP_CONFIDENCE_FLOOR,
    DetectorTrainConfig,
    Prediction,
    evaluate_detector_fold,
    evaluate_predictions,
    train_detector_fold,
)


class DetectorTrainingTest(unittest.TestCase):
    def test_ranked_ap_uses_raw_low_floor_predictions_not_operational_filter(self):
        ground_truth = {
            "held.jpg": ((0, 0, 10, 10), (20, 0, 10, 10)),
        }
        raw_predictions = {
            "held.jpg": (
                Prediction((0, 0, 10, 10), confidence=0.9),
                Prediction((20, 0, 10, 10), confidence=0.1),
            )
        }
        operational_predictions = {
            "held.jpg": (raw_predictions["held.jpg"][0],),
        }

        report = evaluate_predictions(
            ground_truth,
            operational_predictions,
            ap_predictions=raw_predictions,
        )

        self.assertEqual(report.recall, 0.5)
        self.assertEqual(report.precision, 1.0)
        self.assertEqual(report.map50_95, 1.0)

    def test_optional_runtime_load_error_is_wrapped_with_actionable_context(self):
        config = DetectorTrainConfig(
            initial_weights=Path("initial.pt"),
            dataset_yaml=Path("dataset.yaml"),
            seed=17,
            output_root=Path("runs"),
            run_name="fold-0",
        )
        original_import = __import__

        def blocked_import(name, *args, **kwargs):
            if name == "ultralytics":
                raise OSError("WinError 4551: c10.dll blocked")
            return original_import(name, *args, **kwargs)

        with patch("builtins.__import__", side_effect=blocked_import):
            with self.assertRaisesRegex(
                RuntimeError, "Could not load the optional Ultralytics runtime"
            ) as caught:
                train_detector_fold(config)

        self.assertIsInstance(caught.exception.__cause__, OSError)

    def test_train_adapter_imports_ultralytics_lazily_and_uses_gpu_determinism(self):
        calls = []

        class FakeYOLO:
            def __init__(self, weights):
                calls.append(("init", weights))

            def train(self, **kwargs):
                calls.append(("train", kwargs))
                return types.SimpleNamespace(save_dir=kwargs["project"] + "/" + kwargs["name"])

        fake_module = types.SimpleNamespace(YOLO=FakeYOLO)
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            config = DetectorTrainConfig(
                initial_weights=root / "initial.pt",
                dataset_yaml=root / "dataset.yaml",
                seed=17,
                output_root=root / "runs",
                run_name="fold-2",
            )
            with patch.dict(sys.modules, {"ultralytics": fake_module}):
                best = train_detector_fold(config)

        self.assertEqual(calls[0], ("init", str(config.initial_weights)))
        self.assertEqual(
            calls[1],
            (
                "train",
                {
                    "data": str(config.dataset_yaml),
                    "imgsz": 640,
                    "device": 0,
                    "seed": 17,
                    "deterministic": True,
                    "workers": 0,
                    "batch": 16,
                    "epochs": 100,
                    "patience": 20,
                    "project": str(config.output_root),
                    "name": "fold-2",
                    "exist_ok": True,
                },
            ),
        )
        self.assertEqual(best, config.output_root / "fold-2" / "weights" / "best.pt")

    def test_fold_selects_threshold_on_train_side_before_held_out_inference(self):
        calls = []
        train_predictions = {
            "train.jpg": (
                Prediction((0, 0, 10, 10), confidence=0.9),
                Prediction((20, 20, 5, 5), confidence=0.2),
            )
        }
        held_out_predictions = {
            "held.jpg": (Prediction((0, 0, 10, 10), confidence=0.9),)
        }

        def predict(image_keys, confidence):
            calls.append((tuple(image_keys), confidence))
            if tuple(image_keys) == ("train.jpg",):
                return train_predictions
            return held_out_predictions

        with tempfile.TemporaryDirectory() as temporary_directory:
            artifact = Path(temporary_directory) / "fold_0_predictions.json"
            report = evaluate_detector_fold(
                fold=0,
                validation_keys=("train.jpg",),
                held_out_keys=("held.jpg",),
                ground_truth={
                    "train.jpg": ((0, 0, 10, 10),),
                    "held.jpg": ((0, 0, 10, 10),),
                },
                predict=predict,
                artifact_path=artifact,
                threshold_candidates=(0.2, 0.9),
            )
            payload = json.loads(artifact.read_text(encoding="utf-8"))

        self.assertEqual(
            calls,
            [
                (("train.jpg",), AP_CONFIDENCE_FLOOR),
                (("held.jpg",), AP_CONFIDENCE_FLOOR),
            ],
        )
        self.assertEqual(payload["fold"], 0)
        self.assertEqual(payload["ap_confidence_floor"], AP_CONFIDENCE_FLOOR)
        self.assertEqual(payload["confidence_threshold"], 0.9)
        self.assertEqual(payload["threshold_selected_from"], ["train.jpg"])
        self.assertEqual(payload["images"][0]["image_key"], "held.jpg")
        self.assertEqual(
            payload["images"][0]["raw_predictions"][0]["bbox"],
            [0, 0, 10, 10],
        )
        self.assertEqual(
            payload["images"][0]["operational_predictions"][0]["bbox"],
            [0, 0, 10, 10],
        )
        self.assertEqual(report.recall, 1.0)
        self.assertEqual(report.precision, 1.0)

    def test_fold_times_only_full_held_out_calls_per_image(self):
        calls = []
        ground_truth = {
            "validation.jpg": ((0, 0, 10, 10),),
            "held-a.jpg": ((0, 0, 10, 10),),
            "held-b.jpg": ((0, 0, 10, 10),),
        }

        def predict(image_keys, confidence):
            calls.append((tuple(image_keys), confidence))
            return {
                key: (Prediction((0, 0, 10, 10), confidence=0.9),)
                for key in image_keys
            }

        clock_values = iter((10.0, 10.1, 20.0, 20.3))
        latencies = {}
        with tempfile.TemporaryDirectory() as temporary_directory:
            artifact = Path(temporary_directory) / "fold_0_predictions.json"
            evaluate_detector_fold(
                fold=0,
                validation_keys=("validation.jpg",),
                held_out_keys=("held-a.jpg", "held-b.jpg"),
                ground_truth=ground_truth,
                predict=predict,
                artifact_path=artifact,
                threshold_candidates=(0.9,),
                clock=lambda: next(clock_values),
                latency_records=latencies,
            )
            payload = json.loads(artifact.read_text(encoding="utf-8"))

        self.assertEqual(
            calls,
            [
                (("validation.jpg",), AP_CONFIDENCE_FLOOR),
                (("held-a.jpg",), AP_CONFIDENCE_FLOOR),
                (("held-b.jpg",), AP_CONFIDENCE_FLOOR),
            ],
        )
        self.assertAlmostEqual(latencies["held-a.jpg"], 100.0)
        self.assertAlmostEqual(latencies["held-b.jpg"], 300.0)
        self.assertAlmostEqual(payload["images"][0]["latency_ms"], 100.0)
        self.assertAlmostEqual(payload["images"][1]["latency_ms"], 300.0)


if __name__ == "__main__":
    unittest.main()
