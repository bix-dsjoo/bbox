import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.bread_training.train import (
    DetectorTrainConfig,
    Prediction,
    evaluate_detector_fold,
    train_detector_fold,
)


class DetectorTrainingTest(unittest.TestCase):
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

    def test_train_adapter_imports_ultralytics_lazily_and_uses_determinism(self):
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
                    "device": "cpu",
                    "seed": 17,
                    "deterministic": True,
                    "project": str(config.output_root),
                    "name": "fold-2",
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

        self.assertEqual(calls, [(('train.jpg',), 0.0), (('held.jpg',), 0.9)])
        self.assertEqual(payload["fold"], 0)
        self.assertEqual(payload["confidence_threshold"], 0.9)
        self.assertEqual(payload["threshold_selected_from"], ["train.jpg"])
        self.assertEqual(payload["images"][0]["image_key"], "held.jpg")
        self.assertEqual(payload["images"][0]["predictions"][0]["bbox"], [0, 0, 10, 10])
        self.assertEqual(report.recall, 1.0)
        self.assertEqual(report.precision, 1.0)


if __name__ == "__main__":
    unittest.main()
