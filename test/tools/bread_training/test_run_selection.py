import hashlib
import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from tools.bread_training.catalog import Catalog
from tools.bread_training.metrics import DetectorReport, GateDecision, LabelPolicy
from tools.bread_training.run_selection import (
    ModelSelection,
    SelectionError,
    SelectionReport,
    CANONICAL_LABELS,
    REPOSITORY_ROOT,
    audit_manifest_contract,
    build_final_classifier_fingerprint,
    build_manifest,
    choose_detector,
    median_best_epoch,
    main,
    reusable_final_classifier,
    run_selection,
    SelectionConfig,
    _ensure_classifier_validation_scaffold,
    _guard_manifest_path,
    _guard_output_path,
    _materialize_final_classifier_dataset,
    _validate_catalog_sources,
    _write_json_atomic,
)
from tools.bread_training.verifier import (
    VerifierDecision,
    VerifierMetrics,
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class RunSelectionTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.detector_path = self.root / "bread_yolov8n_1class_tray_v0_2.pt"
        self.classifier_path = self.root / "bread_classifier_yolov8n_cls_v1.pt"
        self.detector_path.write_bytes(b"detector")
        self.classifier_path.write_bytes(b"classifier")

    def tearDown(self):
        self.temporary.cleanup()

    def _model(
        self,
        name: str,
        path: Path,
        report: DetectorReport | dict,
        latency: float = 10.0,
    ) -> ModelSelection:
        return ModelSelection(
            name=name,
            path=path,
            sha256=_sha256(path),
            report=report,
            confidence=0.25,
            iou=0.7,
            median_latency_ms=latency,
        )

    def _selection(self, precision: float = 0.946, coverage: float = 0.618):
        detector_report = DetectorReport(
            recall=0.93,
            precision=0.98,
            map50_95=0.93,
            median_iou=0.99,
            median_area_ratio=1.0,
        )
        baseline = self._model(
            "current_detector", self.detector_path, detector_report
        )
        classifier = self._model(
            "final_classifier",
            self.classifier_path,
            {"precision": precision, "coverage": coverage},
        )
        verifier = VerifierDecision(
            kind="none",
            metrics=VerifierMetrics(
                kind="none",
                ambiguous_accuracy_gain=0.0,
                review_reduction_at_policy_precision=0.0,
                auto_precision_drop=0.0,
                p50_ms=0.0,
                p95_ms=0.0,
                supported_class_precision={},
            ),
        )
        return SelectionReport(
            catalog=Catalog(
                labels=tuple(enumerate(CANONICAL_LABELS, start=1)),
                images=(),
                annotations=(),
                raw_root=str(self.root),
            ),
            baseline_detector=baseline,
            detector=baseline,
            detector_gate=GateDecision(True, (), {"baseline": True}),
            classifier=classifier,
            label_policy=LabelPolicy(
                version="bread-label-policy-v2",
                confidence=0.81,
                margin=0.22,
                conservative_classes=(9, 10),
            ),
            classifier_policy_report={
                "precision": precision,
                "coverage": coverage,
            },
            verifier=verifier,
            synthetic_disabled_reason="no_approved_backgrounds",
        )

    def test_classifier_94_percent_floor_can_publish_manifest(self):
        manifest = build_manifest(self._selection())
        self.assertEqual(manifest["classifier"]["oofPrecision"], 0.946)
        self.assertEqual(manifest["classifier"]["oofCoverage"], 0.618)

    def test_classifier_below_94_percent_floor_is_rejected(self):
        with self.assertRaisesRegex(SelectionError, "approved 0.94 floor"):
            build_manifest(self._selection(precision=0.939999))

    def test_failed_new_detectors_keep_current_detector(self):
        selection = self._selection()
        failed_candidate = replace(
            selection.detector,
            name="candidate",
            report=replace(
                selection.detector.report,
                recall=0.99,
                precision=0.99,
                map50_95=0.95,
                median_iou=0.96,
            ),
        )
        chosen, decision = choose_detector(
            selection.baseline_detector, (failed_candidate,)
        )
        manifest = build_manifest(
            replace(selection, detector=chosen, detector_gate=decision)
        )
        self.assertEqual(chosen.name, "current_detector")
        self.assertEqual(decision.failed_gates, ("median_iou",))
        self.assertEqual(
            manifest["detector"]["file"],
            "bread_yolov8n_1class_tray_v0_2.pt",
        )

    def test_manifest_uses_none_verifier_and_ordered_labels(self):
        manifest = build_manifest(self._selection())
        self.assertEqual(
            manifest["verifier"],
            {
                "kind": "none",
                "file": None,
                "sha256": None,
                "scoreThreshold": None,
                "marginThreshold": None,
            },
        )
        self.assertEqual(
            [item["id"] for item in manifest["labels"]], list(range(1, 21))
        )
        self.assertEqual(
            manifest["quality"],
            {
                "minBoxSize": 45,
                "maxAreaRatio": 0.38,
                "edgeMarginPx": 2,
                "duplicateIou": 0.95,
            },
        )

    def test_build_manifest_refuses_stale_selected_file_hash(self):
        selection = self._selection()
        self.classifier_path.write_bytes(b"changed")
        with self.assertRaisesRegex(SelectionError, "classifier sha256 mismatch"):
            build_manifest(selection)

    def test_manifest_audit_recomputes_sibling_hashes_and_thresholds(self):
        manifest_path = self.root / "bread_pipeline_manifest.json"
        manifest_path.write_text(
            json.dumps(build_manifest(self._selection())), encoding="utf-8"
        )
        self.assertEqual(
            audit_manifest_contract(manifest_path),
            {
                "ok": True,
                "pipelineVersion": "bread-pipeline-v1",
                "verifierKind": "none",
            },
        )
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
        payload["classifier"]["acceptMargin"] = 1.01
        manifest_path.write_text(json.dumps(payload), encoding="utf-8")
        with self.assertRaisesRegex(SelectionError, "acceptMargin"):
            audit_manifest_contract(manifest_path)

    def test_manifest_audit_rejects_non_exact_schema_contract(self):
        manifest_path = self.root / "bread_pipeline_manifest.json"
        mutations = {
            "policy version": lambda item: item.update(policyVersion="wrong"),
            "detector imgsz": lambda item: item["detector"].update(imgsz=320),
            "classifier imgsz": lambda item: item["classifier"].update(imgsz=640),
            "label name": lambda item: item["labels"][15].update(name="Wrong"),
            "conservative classes": lambda item: item["classifier"].update(
                conservativeClasses=[10, 9]
            ),
            "unknown key": lambda item: item.update(extra=True),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                payload = build_manifest(self._selection())
                mutate(payload)
                manifest_path.write_text(json.dumps(payload), encoding="utf-8")
                with self.assertRaises(SelectionError):
                    audit_manifest_contract(manifest_path)

    def test_manifest_audit_rejects_paths_outside_manifest_directory(self):
        manifest_path = self.root / "bread_pipeline_manifest.json"
        payload = build_manifest(self._selection())
        payload["detector"]["file"] = "../bread_yolov8n_1class_tray_v0_2.pt"
        manifest_path.write_text(json.dumps(payload), encoding="utf-8")
        with self.assertRaisesRegex(SelectionError, "local sibling filename"):
            audit_manifest_contract(manifest_path)

    def test_median_best_epoch_is_integer_and_requires_five_positive_values(self):
        self.assertEqual(median_best_epoch((29, 20, 35, 21, 18)), 21)
        with self.assertRaisesRegex(SelectionError, "five"):
            median_best_epoch((1, 2, 3))
        with self.assertRaisesRegex(SelectionError, "positive"):
            median_best_epoch((1, 2, 0, 4, 5))

    def test_final_classifier_reuse_requires_exact_fingerprint_and_weight_hash(self):
        weights = self.root / "last.pt"
        weights.write_bytes(b"final")
        marker = self.root / "completion.json"
        fingerprint = build_final_classifier_fingerprint(
            catalog_sha256="a" * 64,
            split_sha256="b" * 64,
            dataset_manifest_sha256="c" * 64,
            initial_weights_path=self.classifier_path,
            epochs=21,
        )
        marker.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "trainingFingerprint": fingerprint,
                    "finalWeights": str(weights),
                    "finalWeightsSha256": _sha256(weights),
                }
            ),
            encoding="utf-8",
        )
        self.assertEqual(
            reusable_final_classifier(marker, fingerprint), weights.resolve()
        )
        changed = dict(fingerprint)
        changed["epochs"] = 22
        self.assertIsNone(reusable_final_classifier(marker, changed))
        weights.write_bytes(b"tampered")
        self.assertIsNone(reusable_final_classifier(marker, fingerprint))

    def test_final_classifier_reuse_cannot_redirect_outside_final_root(self):
        final_root = self.root / "final_classifier"
        final_root.mkdir()
        outside = self.root / "outside.pt"
        outside.write_bytes(b"outside")
        fingerprint = build_final_classifier_fingerprint(
            catalog_sha256="a" * 64,
            split_sha256="b" * 64,
            dataset_manifest_sha256="c" * 64,
            initial_weights_path=self.classifier_path,
            epochs=21,
        )
        marker = final_root / "completion.json"
        marker.write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "trainingFingerprint": fingerprint,
                    "finalWeights": str(outside),
                    "finalWeightsSha256": _sha256(outside),
                }
            ),
            encoding="utf-8",
        )
        self.assertIsNone(reusable_final_classifier(marker, fingerprint))

    def test_atomic_json_has_platform_independent_lf_bytes(self):
        path = self.root / "canonical.json"
        payload = {"schemaVersion": 1, "value": "bread"}
        _write_json_atomic(path, payload)
        expected = (json.dumps(payload, indent=2, ensure_ascii=False) + "\n").encode(
            "utf-8"
        )
        self.assertEqual(path.read_bytes(), expected)

    def test_final_dataset_has_one_validation_scaffold_image_per_class(self):
        dataset = self.root / "dataset"
        for category_id in range(1, 21):
            class_dir = dataset / "train" / f"{category_id:02d}_bread"
            class_dir.mkdir(parents=True)
            (class_dir / "sample.jpg").write_bytes(f"bread-{category_id}".encode())
        _ensure_classifier_validation_scaffold(dataset)
        validation_files = sorted((dataset / "val").glob("*/*"))
        self.assertEqual(len(validation_files), 20)
        self.assertEqual(
            [item.parent.name for item in validation_files],
            [f"{item:02d}_bread" for item in range(1, 21)],
        )

    def test_write_guards_require_repository_outputs_and_models(self):
        self.assertEqual(
            _guard_output_path(REPOSITORY_ROOT / "outputs" / "selection"),
            (REPOSITORY_ROOT / "outputs" / "selection").resolve(),
        )
        self.assertEqual(
            _guard_manifest_path(
                REPOSITORY_ROOT / "models" / "bread_pipeline_manifest.json"
            ),
            (REPOSITORY_ROOT / "models" / "bread_pipeline_manifest.json").resolve(),
        )
        with self.assertRaisesRegex(SelectionError, "outputs"):
            _guard_output_path(self.root / "audit.json")
        with self.assertRaisesRegex(SelectionError, "models"):
            _guard_manifest_path(self.root / "manifest.json")
        detector = REPOSITORY_ROOT / "models" / "bread_yolov8n_1class_tray_v0_2.pt"
        original = detector.read_bytes()
        with self.assertRaisesRegex(SelectionError, "bread_pipeline_manifest.json"):
            _guard_manifest_path(detector)
        self.assertEqual(detector.read_bytes(), original)
        with self.assertRaisesRegex(SelectionError, "bread_pipeline_manifest.json"):
            _guard_manifest_path(REPOSITORY_ROOT / "models" / "other.json")

    def test_catalog_source_validation_detects_changed_or_outside_raw_files(self):
        raw_root = self.root / "raw"
        raw_root.mkdir()
        source = raw_root / "bread.jpg"
        source.write_bytes(b"bread")
        payload = {
            "images": [
                {
                    "key": "bread.jpg",
                    "absolute_path": str(source),
                    "sha256": _sha256(source),
                }
            ]
        }
        _validate_catalog_sources(payload, raw_root)
        source.write_bytes(b"changed")
        with self.assertRaisesRegex(SelectionError, "sha256 mismatch"):
            _validate_catalog_sources(payload, raw_root)
        outside = self.root / "outside.jpg"
        outside.write_bytes(b"outside")
        payload["images"][0].update(
            absolute_path=str(outside), sha256=_sha256(outside)
        )
        with self.assertRaisesRegex(SelectionError, "outside raw root"):
            _validate_catalog_sources(payload, raw_root)

    def test_final_classifier_dataset_copies_raw_singles_independently(self):
        raw_root = self.root / "raw"
        raw_root.mkdir()
        labels = []
        images = []
        for category_id in range(1, 21):
            source = raw_root / f"bread-{category_id}.jpg"
            source.write_bytes(f"source-{category_id}".encode())
            labels.append({"id": category_id, "name": f"Bread {category_id}"})
            images.append(
                {
                    "key": source.name,
                    "absolute_path": str(source),
                    "sha256": _sha256(source),
                    "source_kind": "single_bread",
                    "category_id": category_id,
                }
            )
        dataset = self.root / "dataset-copy"
        _materialize_final_classifier_dataset(
            {"labels": labels, "images": images, "annotations": []}, dataset
        )
        copied = next((dataset / "train" / "01_bread_1").iterdir())
        copied.write_bytes(b"mutated-generated-copy")
        self.assertEqual((raw_root / "bread-1.jpg").read_bytes(), b"source-1")

    def test_run_selection_consumes_reports_and_never_trains_failed_detector(self):
        with tempfile.TemporaryDirectory() as raw_name, tempfile.TemporaryDirectory(
            dir=REPOSITORY_ROOT / "outputs"
        ) as output_name, tempfile.TemporaryDirectory(
            dir=REPOSITORY_ROOT / "models"
        ) as model_name:
            raw_root = Path(raw_name)
            output = Path(output_name)
            model_root = Path(model_name)
            labels = [
                {"id": item, "name": name}
                for item, name in enumerate(CANONICAL_LABELS, start=1)
            ]
            catalog = output / "catalog.json"
            catalog.write_text(
                json.dumps(
                    {
                        "raw_root": str(raw_root),
                        "labels": labels,
                        "images": [],
                        "annotations": [],
                    }
                ),
                encoding="utf-8",
            )
            split = output / "split.json"
            split.write_text("{}", encoding="utf-8")
            detector = model_root / "bread_yolov8n_1class_tray_v0_2.pt"
            detector.write_bytes(b"detector")
            baseline_report = output / "baseline.json"
            baseline_report.write_text(
                json.dumps(
                    {
                        "model": str(detector),
                        "metrics": {
                            "recall": 0.929369623503644,
                            "precision": 0.9524455163923854,
                            "map50_95": 0.9328948836382315,
                            "median_iou": 0.9999785606975117,
                            "median_area_ratio": 0.9999985880508161,
                        },
                        "median_latency_ms": 154.47,
                    }
                ),
                encoding="utf-8",
            )
            candidate_root = output / "candidates"
            for candidate_name, median_iou in (
                ("current_finetune_real", 0.9673019765356228),
                ("coco_yolov8n_real", 0.9642949614214145),
            ):
                root = candidate_root / candidate_name
                root.mkdir(parents=True)
                (root / "candidate_report.json").write_text(
                    json.dumps(
                        {
                            "candidate": candidate_name,
                            "metrics": {
                                "recall": 0.988,
                                "precision": 0.99,
                                "map50_95": 0.95,
                                "median_iou": median_iou,
                                "median_area_ratio": 1.0,
                            },
                            "median_latency_ms": 125.0,
                            "folds": [{"confidence_threshold": 0.55}],
                        }
                    ),
                    encoding="utf-8",
                )
            classifier_root = output / "classifier"
            classifier_root.mkdir()
            (classifier_root / "classifier_report.json").write_text(
                json.dumps(
                    {
                        "policy": {
                            "version": "bread-label-policy-v2",
                            "confidence": 0.0,
                            "margin": 0.5,
                            "conservative_classes": [9, 10],
                        },
                        "deployment_policy_report": {
                            "precision": 0.9438775510204082,
                            "coverage": 0.7686274509803922,
                        },
                        "latency_ms": {"p50": 1.0},
                    }
                ),
                encoding="utf-8",
            )
            for fold, epoch in enumerate((29, 20, 35, 21, 18)):
                csv_path = classifier_root / f"fold_{fold}" / "train" / "results.csv"
                csv_path.parent.mkdir(parents=True)
                csv_path.write_text(
                    "epoch,metrics/accuracy_top1\n" f"{epoch},0.99\n",
                    encoding="utf-8",
                )
            classifier = model_root / "bread_classifier_yolov8n_cls_v1.pt"
            classifier.write_bytes(b"classifier")
            config = SelectionConfig(
                raw_root=raw_root,
                catalog_path=catalog,
                split_path=split,
                baseline_detector_report=baseline_report,
                candidate_root=candidate_root,
                classifier_root=classifier_root,
                output_root=output / "selection",
                manifest_path=model_root / "bread_pipeline_manifest.json",
            )
            with patch(
                "tools.bread_training.run_selection._prepare_final_classifier",
                return_value=classifier,
            ), patch(
                "tools.bread_training.run_selection._guard_manifest_path",
                return_value=config.manifest_path.resolve(),
            ), patch(
                "tools.bread_training.run_selection.build_detector_all_data"
            ) as detector_dataset, patch(
                "tools.bread_training.run_selection._yolo_class"
            ) as yolo:
                selection = run_selection(config, progress=lambda _: None)
            self.assertEqual(selection.detector.name, "current_detector")
            self.assertEqual(selection.detector_gate.failed_gates, ("median_iou",))
            detector_dataset.assert_not_called()
            yolo.assert_not_called()
            report = json.loads(
                (output / "selection" / "selection_report.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(report["classifier"]["finalTrainingSamples"], 3740)
            self.assertEqual(report["classifier"]["oofClaimsSource"], "five_fold_weights_only")

    def test_audit_cli_refuses_output_outside_repository_outputs(self):
        manifest = self.root / "bread_pipeline_manifest.json"
        manifest.write_text(json.dumps(build_manifest(self._selection())), encoding="utf-8")
        with self.assertRaisesRegex(SelectionError, "outputs"):
            main(
                [
                    "audit-handoff",
                    "--manifest",
                    str(manifest),
                    "--output",
                    str(self.root / "audit.json"),
                ]
            )
        self.assertFalse((self.root / "audit.json").exists())


if __name__ == "__main__":
    unittest.main()
