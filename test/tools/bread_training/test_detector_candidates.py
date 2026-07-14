import hashlib
import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from tools.bread_training.train import (
    AP_CONFIDENCE_FLOOR,
    DetectorCandidateConfig,
    Prediction,
    _best_epoch,
    _load_candidate_ground_truth,
    detector_candidate_matrix,
    fast_detector_candidate_matrix,
    run_detector_candidate_oof,
)


def _write_fold(root: Path, fold: int) -> None:
    dataset = root / f"fold_{fold}"
    for split in ("train", "validation", "test"):
        image = dataset / "images" / split / f"fold-{fold}-{split}.jpg"
        image.parent.mkdir(parents=True, exist_ok=True)
        image.write_bytes(b"generated-copy")
    (dataset / "dataset.yaml").write_text("names: {0: bread}\n", encoding="utf-8")
    manifest = {
        "schema_version": 1,
        "dataset_kind": "fold",
        "heldout_fold": fold,
        "validation_fold": (fold + 1) % 5,
        "splits": {
            split: [
                {
                    "image_key": f"fold-{fold}-{split}.jpg",
                    "sha256": "0" * 64,
                    "source_fold": fold if split == "test" else (fold + 1) % 5,
                    "annotation_ids": [f"{fold}:{split}"],
                    "output_image": f"images/{split}/fold-{fold}-{split}.jpg",
                    "output_label": f"labels/{split}/fold-{fold}-{split}.txt",
                }
            ]
            for split in ("train", "validation", "test")
        },
    }
    (dataset / "source_manifest.json").write_text(
        json.dumps(manifest), encoding="utf-8"
    )


class DetectorCandidateTest(unittest.TestCase):
    def test_fast_candidate_matrix_has_fixed_real_only_profiles(self):
        a2, b2 = fast_detector_candidate_matrix(
            Path("models/current.pt"),
            Path("datasets/folds"),
            Path("outputs/fast"),
        )

        self.assertEqual(
            (a2.name, b2.name),
            ("candidate_a2_tight", "candidate_b2_recall"),
        )
        self.assertEqual(a2.initial_weights, Path("models/current.pt"))
        self.assertEqual(b2.initial_weights, Path("yolov8n.pt"))
        self.assertEqual(a2.folds, (0,))
        self.assertEqual(b2.folds, (0,))
        self.assertEqual((a2.epochs, a2.patience), (12, 4))
        self.assertEqual((b2.epochs, b2.patience), (12, 4))
        self.assertEqual(
            (a2.mosaic, a2.close_mosaic, a2.translate, a2.scale),
            (0.25, 6, 0.05, 0.20),
        )
        self.assertEqual(
            (b2.mosaic, b2.close_mosaic, b2.translate, b2.scale),
            (0.50, 8, 0.10, 0.30),
        )
        self.assertTrue(all(item.synthetic_ratio == 0.0 for item in (a2, b2)))

    def test_candidate_runner_trains_only_requested_folds(self):
        train_calls = []

        def train_fold(config):
            train_calls.append(config.run_name)
            weights = config.output_root / config.run_name / "weights" / "best.pt"
            weights.parent.mkdir(parents=True, exist_ok=True)
            weights.write_bytes(config.run_name.encode("ascii"))
            (weights.parents[1] / "results.csv").write_text(
                "epoch\n1\n", encoding="utf-8"
            )
            return weights

        class FakePredictor:
            def __init__(self, weights, paths_by_key, device=0):
                pass

            def __call__(self, image_keys, confidence):
                return {
                    key: (Prediction((0, 0, 10, 10), 0.9),) for key in image_keys
                }

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            datasets = root / "datasets"
            for fold in (0, 3):
                _write_fold(datasets, fold)
            initial = root / "initial.pt"
            initial.write_bytes(b"initial")
            config = DetectorCandidateConfig(
                name="candidate",
                initial_weights=initial,
                fold_dataset_root=datasets,
                output_root=root / "outputs",
                folds=(0, 3),
                epochs=1,
            )

            report = run_detector_candidate_oof(
                config,
                train_fold=train_fold,
                predictor_factory=FakePredictor,
                ground_truth_loader=lambda dataset, split: {
                    f"fold-{dataset.name[-1]}-{split}.jpg": ((0, 0, 10, 10),)
                },
                progress=None,
            )

        self.assertEqual(train_calls, ["fold_0", "fold_3"])
        self.assertEqual(
            [item["fold"] for item in report.fold_artifacts],
            [0, 3],
        )

    def test_ground_truth_uses_exif_oriented_image_dimensions(self):
        from PIL import Image

        with tempfile.TemporaryDirectory() as temporary_directory:
            dataset = Path(temporary_directory) / "fold_0"
            _write_fold(dataset.parent, 0)
            image_path = dataset / "images" / "test" / "fold-0-test.jpg"
            exif = Image.Exif()
            exif[274] = 6
            Image.new("RGB", (40, 30)).save(image_path, exif=exif)
            label_path = dataset / "labels" / "test" / "fold-0-test.txt"
            label_path.parent.mkdir(parents=True, exist_ok=True)
            label_path.write_text("0 0.5 0.5 0.5 0.25\n", encoding="utf-8")

            result = _load_candidate_ground_truth(dataset, "test")

        self.assertEqual(result["fold-0-test.jpg"], ((7.5, 15.0, 15.0, 10.0),))

    def test_best_epoch_uses_one_based_max_map50_95_with_latest_tie(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            run_root = Path(temporary_directory)
            (run_root / "results.csv").write_text(
                "epoch,metrics/mAP50(B),metrics/mAP50-95(B)\n"
                "1,0.00,0.90\n"
                "2,1.00,0.82\n"
                "3,0.50,0.90\n",
                encoding="utf-8",
            )

            self.assertEqual(_best_epoch(run_root), 3)

    def test_reuse_fingerprint_tracks_initial_bytes_and_training_settings(self):
        train_calls = []

        def train_fold(config):
            train_calls.append((config.run_name, config.batch))
            weights = config.output_root / config.run_name / "weights" / "best.pt"
            weights.parent.mkdir(parents=True, exist_ok=True)
            weights.write_bytes(f"{config.run_name}:{config.batch}".encode("ascii"))
            (weights.parents[1] / "results.csv").write_text(
                "epoch\n1\n", encoding="utf-8"
            )
            return weights

        class FakePredictor:
            def __init__(self, weights, paths_by_key, device=0):
                pass

            def __call__(self, image_keys, confidence):
                return {key: (Prediction((0, 0, 10, 10), 0.9),) for key in image_keys}

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            datasets = root / "datasets"
            for fold in range(5):
                _write_fold(datasets, fold)
            initial = root / "initial.pt"
            initial.write_bytes(b"initial-v1")
            config = DetectorCandidateConfig(
                name="candidate",
                initial_weights=initial,
                fold_dataset_root=datasets,
                output_root=root / "outputs",
                epochs=1,
            )
            kwargs = {
                "train_fold": train_fold,
                "predictor_factory": FakePredictor,
                "ground_truth_loader": lambda dataset, split: {
                    f"fold-{dataset.name[-1]}-{split}.jpg": ((0, 0, 10, 10),)
                },
                "progress": None,
            }

            run_detector_candidate_oof(config, **kwargs)
            self.assertEqual(len(train_calls), 5)
            marker = json.loads(
                (config.output_root / "fold_0" / "candidate_training.json").read_text(
                    encoding="utf-8"
                )
            )
            fingerprint = marker["training_fingerprint"]
            self.assertEqual(
                fingerprint["initial_weights_sha256"],
                hashlib.sha256(b"initial-v1").hexdigest(),
            )
            self.assertEqual(
                {
                    key: fingerprint[key]
                    for key in (
                        "imgsz",
                        "device",
                        "seed",
                        "deterministic",
                        "workers",
                        "batch",
                        "epochs",
                        "patience",
                        "synthetic_ratio",
                        "dataset_manifest_sha256",
                        "candidate",
                        "evaluator_schema_version",
                        "trainer_schema_version",
                        "folds",
                        "mosaic",
                        "close_mosaic",
                        "translate",
                        "scale",
                    )
                },
                {
                    "imgsz": 640,
                    "device": 0,
                    "seed": 20260714,
                    "deterministic": True,
                    "workers": 0,
                    "batch": 16,
                    "epochs": 1,
                    "patience": 20,
                    "synthetic_ratio": 0.0,
                    "dataset_manifest_sha256": fingerprint["dataset_manifest_sha256"],
                    "candidate": "candidate",
                    "evaluator_schema_version": 3,
                    "trainer_schema_version": 2,
                    "folds": [0, 1, 2, 3, 4],
                    "mosaic": 1.0,
                    "close_mosaic": 10,
                    "translate": 0.1,
                    "scale": 0.5,
                },
            )

            run_detector_candidate_oof(config, **kwargs)
            self.assertEqual(len(train_calls), 5)

            initial.write_bytes(b"initial-v2")
            run_detector_candidate_oof(config, **kwargs)
            self.assertEqual(len(train_calls), 10)

            run_detector_candidate_oof(replace(config, batch=8), **kwargs)
            self.assertEqual(len(train_calls), 15)

    def test_reuse_retrains_when_best_weights_hash_changes(self):
        train_calls = []

        def train_fold(config):
            train_calls.append(config.run_name)
            weights = config.output_root / config.run_name / "weights" / "best.pt"
            weights.parent.mkdir(parents=True, exist_ok=True)
            weights.write_bytes(config.run_name.encode("ascii"))
            (weights.parents[1] / "results.csv").write_text(
                "epoch\n1\n", encoding="utf-8"
            )
            return weights

        class FakePredictor:
            def __init__(self, weights, paths_by_key, device=0):
                pass

            def __call__(self, image_keys, confidence):
                return {key: (Prediction((0, 0, 10, 10), 0.9),) for key in image_keys}

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            datasets = root / "datasets"
            for fold in range(5):
                _write_fold(datasets, fold)
            initial = root / "initial.pt"
            initial.write_bytes(b"initial")
            config = DetectorCandidateConfig(
                name="candidate",
                initial_weights=initial,
                fold_dataset_root=datasets,
                output_root=root / "outputs",
                epochs=1,
            )
            kwargs = {
                "train_fold": train_fold,
                "predictor_factory": FakePredictor,
                "ground_truth_loader": lambda dataset, split: {
                    f"fold-{dataset.name[-1]}-{split}.jpg": ((0, 0, 10, 10),)
                },
                "progress": None,
            }

            run_detector_candidate_oof(config, **kwargs)
            for fold in range(5):
                (config.output_root / f"fold_{fold}" / "weights" / "best.pt").write_bytes(
                    b"corrupted"
                )
            run_detector_candidate_oof(config, **kwargs)

        self.assertEqual(len(train_calls), 10)

    def test_reuse_retrains_when_completion_marker_is_malformed(self):
        train_calls = []

        def train_fold(config):
            train_calls.append(config.run_name)
            weights = config.output_root / config.run_name / "weights" / "best.pt"
            weights.parent.mkdir(parents=True, exist_ok=True)
            weights.write_bytes(config.run_name.encode("ascii"))
            (weights.parents[1] / "results.csv").write_text(
                "epoch\n1\n", encoding="utf-8"
            )
            return weights

        class FakePredictor:
            def __init__(self, weights, paths_by_key, device=0):
                pass

            def __call__(self, image_keys, confidence):
                return {key: (Prediction((0, 0, 10, 10), 0.9),) for key in image_keys}

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            datasets = root / "datasets"
            for fold in range(5):
                _write_fold(datasets, fold)
            initial = root / "initial.pt"
            initial.write_bytes(b"initial")
            config = DetectorCandidateConfig(
                name="candidate",
                initial_weights=initial,
                fold_dataset_root=datasets,
                output_root=root / "outputs",
                epochs=1,
            )
            kwargs = {
                "train_fold": train_fold,
                "predictor_factory": FakePredictor,
                "ground_truth_loader": lambda dataset, split: {
                    f"fold-{dataset.name[-1]}-{split}.jpg": ((0, 0, 10, 10),)
                },
                "progress": None,
            }

            run_detector_candidate_oof(config, **kwargs)
            for fold in range(5):
                marker = config.output_root / f"fold_{fold}" / "candidate_training.json"
                marker.write_text("[]" if fold == 0 else "{", encoding="utf-8")
            run_detector_candidate_oof(config, **kwargs)

        self.assertEqual(len(train_calls), 10)

    def test_real_only_candidate_matrix_is_exact(self):
        configs = detector_candidate_matrix(
            current_weights=Path("current.pt"),
            fold_dataset_root=Path("datasets/folds"),
            output_root=Path("outputs/candidates"),
        )

        self.assertEqual(
            [item.name for item in configs],
            ["current_finetune_real", "coco_yolov8n_real"],
        )
        self.assertEqual(configs[1].initial_weights, Path("yolov8n.pt"))
        self.assertTrue(all(item.synthetic_ratio == 0 for item in configs))

    def test_candidate_artifacts_are_raw_operational_hashed_and_real_only(self):
        calls = []

        def train_fold(config):
            calls.append(("train", config.run_name, config.epochs))
            weights = config.output_root / config.run_name / "weights" / "best.pt"
            weights.parent.mkdir(parents=True, exist_ok=True)
            weights.write_bytes(config.run_name.encode("ascii"))
            results = weights.parents[1] / "results.csv"
            results.write_text("epoch\n1\n", encoding="utf-8")
            return weights

        class FakePredictor:
            def __init__(self, weights, paths_by_key, device=0):
                calls.append(("predictor", weights.name, device))

            def __call__(self, image_keys, confidence):
                calls.append(("predict", tuple(image_keys), confidence))
                return {
                    key: (
                        Prediction((0, 0, 10, 10), 0.9),
                        Prediction((20, 20, 5, 5), 0.01),
                    )
                    for key in image_keys
                }

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            datasets = root / "datasets"
            for fold in range(5):
                _write_fold(datasets, fold)
            initial = root / "initial.pt"
            initial.write_bytes(b"initial")
            config = DetectorCandidateConfig(
                name="candidate",
                initial_weights=initial,
                fold_dataset_root=datasets,
                output_root=root / "outputs",
                epochs=1,
            )

            artifact = run_detector_candidate_oof(
                config,
                train_fold=train_fold,
                predictor_factory=FakePredictor,
                ground_truth_loader=lambda _dataset, split: {
                    f"fold-{_dataset.name[-1]}-{split}.jpg": ((0, 0, 10, 10),)
                },
                progress=None,
            )

            self.assertEqual(len(artifact.fold_predictions), 5)
            image = artifact.fold_predictions[0]["images"][0]
            self.assertIn("raw_predictions", image)
            self.assertIn("operational_predictions", image)
            self.assertIn("ground_truth", image)
            self.assertIn("latency_ms", image)
            self.assertEqual(artifact.best_epochs, (1, 1, 1, 1, 1))
            self.assertEqual(
                len(
                    {
                        image["image_key"]
                        for fold in artifact.fold_predictions
                        for image in fold["images"]
                    }
                ),
                5,
            )
            for fold in artifact.fold_predictions:
                self.assertEqual(fold["ap_confidence_floor"], AP_CONFIDENCE_FLOOR)
                self.assertRegex(fold["model_sha256"], r"^[0-9a-f]{64}$")
                self.assertRegex(fold["dataset_manifest_sha256"], r"^[0-9a-f]{64}$")
                self.assertEqual(fold["synthetic_record_count"], 0)
                self.assertEqual(fold["threshold_selected_from_split"], "validation")
            inference_calls = [call for call in calls if call[0] == "predict"]
            self.assertTrue(all(call[2] == AP_CONFIDENCE_FLOOR for call in inference_calls))

    def test_candidate_rejects_synthetic_manifest_records(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            for fold in range(5):
                _write_fold(root, fold)
            manifest_path = root / "fold_0" / "source_manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["splits"]["train"][0]["synthetic"] = True
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            initial = root / "initial.pt"
            initial.write_bytes(b"initial")

            with self.assertRaisesRegex(ValueError, "synthetic"):
                run_detector_candidate_oof(
                    DetectorCandidateConfig(
                        name="candidate",
                        initial_weights=initial,
                        fold_dataset_root=root,
                        output_root=root / "outputs",
                        epochs=1,
                    ),
                    train_fold=lambda config: Path("unused.pt"),
                    predictor_factory=lambda *args, **kwargs: None,
                )


if __name__ == "__main__":
    unittest.main()
