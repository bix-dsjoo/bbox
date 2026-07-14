import json
import tempfile
import unittest
from pathlib import Path

from tools.bread_training.visualize_detector_oof import collect_source_images


class VisualizeDetectorOofTest(unittest.TestCase):
    def test_collect_source_images_uses_oof_predictions_from_all_folds(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            records = []
            expected = (
                (0, "Test_20260714/E0501.jpg"),
                (2, "Test_20260714/H0501.jpg"),
                (4, "Test_20260714/M0501.jpg"),
            )
            for fold in range(5):
                artifact_path = root / f"fold_{fold}_predictions.json"
                images = []
                for expected_fold, image_key in expected:
                    if expected_fold == fold:
                        images.append(
                            {
                                "image_key": image_key,
                                "ground_truth": [[0, 0, 10, 10]],
                                "operational_predictions": [
                                    {
                                        "bbox": [0, 0, 10, 10],
                                        "confidence": 0.9,
                                    }
                                ],
                                "misses": 0,
                                "false_positives": 0,
                                "latency_ms": 10.0,
                            }
                        )
                artifact_path.write_text(
                    json.dumps(
                        {
                            "fold": fold,
                            "model_sha256": str(fold) * 64,
                            "images": images,
                        }
                    ),
                    encoding="utf-8",
                )
                records.append(
                    {
                        "fold": fold,
                        "path": str(artifact_path.resolve()),
                        "modelSha256": str(fold) * 64,
                    }
                )
            selection_path = root / "fast_selection.json"
            selection_path.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "winner": "candidate_b2_recall",
                        "fullOof": {"artifacts": records},
                    }
                ),
                encoding="utf-8",
            )

            images = collect_source_images(
                selection_path, source_prefix="Test_20260714/"
            )

        self.assertEqual(
            [image.image_key for image in images],
            [
                "Test_20260714/E0501.jpg",
                "Test_20260714/H0501.jpg",
                "Test_20260714/M0501.jpg",
            ],
        )
        self.assertEqual({image.fold for image in images}, {0, 2, 4})

    def test_collect_rejects_duplicate_image_across_fold_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            records = []
            for fold in range(5):
                artifact_path = root / f"fold_{fold}.json"
                artifact_path.write_text(
                    json.dumps(
                        {
                            "fold": fold,
                            "model_sha256": str(fold) * 64,
                            "images": [
                                {
                                    "image_key": "Test_20260714/E0501.jpg",
                                    "ground_truth": [],
                                    "operational_predictions": [],
                                    "misses": 0,
                                    "false_positives": 0,
                                    "latency_ms": 1.0,
                                }
                            ],
                        }
                    ),
                    encoding="utf-8",
                )
                records.append(
                    {
                        "fold": fold,
                        "path": str(artifact_path),
                        "modelSha256": str(fold) * 64,
                    }
                )
            selection = root / "selection.json"
            selection.write_text(
                json.dumps({"fullOof": {"artifacts": records}}), encoding="utf-8"
            )

            with self.assertRaisesRegex(ValueError, "duplicate OOF image"):
                collect_source_images(
                    selection, source_prefix="Test_20260714/"
                )


if __name__ == "__main__":
    unittest.main()
