from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.detectors.bread_pipeline_manifest import (
    ManifestError,
    load_pipeline_manifest,
    resolve_model_paths,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CANONICAL_LABELS = (
    "Walnut Donut",
    "Croffle",
    "Waffle",
    "Scon",
    "Half-moon Croissant",
    "Croissant",
    "Flower Bread",
    "Almond Scon",
    "Dinner Roll",
    "Sugar Donut",
    "Bagel",
    "Egg Tart",
    "Muffin",
    "Burger",
    "Sandwich",
    "Grain Campagne",
    "Almond Campagne",
    "Mini Bread",
    "Pastry Bread",
    "Plain Bread",
)


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


class BreadPipelineManifestTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.detector_bytes = b"detector weights"
        self.classifier_bytes = b"classifier weights"
        self.detector_hash = sha256_bytes(self.detector_bytes)
        self.classifier_hash = sha256_bytes(self.classifier_bytes)
        (self.root / "detector.pt").write_bytes(self.detector_bytes)
        (self.root / self.classifier_filename).write_bytes(self.classifier_bytes)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @property
    def classifier_filename(self) -> str:
        return f"bread_classifier_yolov8n_cls_v1_{self.classifier_hash}.pt"

    def valid_payload(self) -> dict:
        return {
            "schemaVersion": 1,
            "pipelineVersion": "bread-pipeline-v1",
            "policyVersion": "bread-label-policy-v2",
            "detector": {
                "file": "detector.pt",
                "sha256": self.detector_hash,
                "imgsz": 640,
                "confidence": 0.25,
                "iou": 0.7,
            },
            "classifier": {
                "file": self.classifier_filename,
                "sha256": self.classifier_hash,
                "imgsz": 224,
                "acceptConfidence": 0.0,
                "acceptMargin": 0.5,
                "conservativeClasses": [9, 10],
                "oofPrecision": 0.94,
                "oofCoverage": 0.75,
            },
            "verifier": {
                "kind": "none",
                "file": None,
                "sha256": None,
                "scoreThreshold": None,
                "marginThreshold": None,
            },
            "quality": {
                "minBoxSize": 45,
                "maxAreaRatio": 0.38,
                "edgeMarginPx": 2,
                "duplicateIou": 0.95,
            },
            "labels": [
                {"id": category_id, "name": name}
                for category_id, name in enumerate(CANONICAL_LABELS, start=1)
            ],
        }

    def write_manifest(self, payload: dict | None = None) -> Path:
        path = self.root / "bread_pipeline_manifest.json"
        path.write_text(json.dumps(payload or self.valid_payload()), encoding="utf-8")
        return path

    def test_loads_typed_schema_and_resolves_sibling_weights(self) -> None:
        path = self.write_manifest()

        manifest = load_pipeline_manifest(path)
        resolved = resolve_model_paths(path, manifest)

        self.assertEqual(manifest.schema_version, 1)
        self.assertEqual(manifest.pipeline_version, "bread-pipeline-v1")
        self.assertEqual(manifest.policy_version, "bread-label-policy-v2")
        self.assertIsInstance(manifest.detector, dict)
        self.assertIsInstance(manifest.classifier, dict)
        self.assertIsInstance(manifest.verifier, dict)
        self.assertIsInstance(manifest.quality, dict)
        self.assertEqual(
            tuple(label.id for label in manifest.labels), tuple(range(1, 21))
        )
        self.assertEqual(
            tuple(label.name for label in manifest.labels), CANONICAL_LABELS
        )
        self.assertEqual(manifest.labels[15].name, "Grain Campagne")
        self.assertEqual(resolved.detector_path, (self.root / "detector.pt").resolve())
        self.assertEqual(
            resolved.classifier_path,
            (self.root / self.classifier_filename).resolve(),
        )
        self.assertIsNone(resolved.classifier_error)

    def test_detector_hash_mismatch_is_fatal(self) -> None:
        payload = self.valid_payload()
        payload["detector"]["sha256"] = "0" * 64
        path = self.write_manifest(payload)

        with self.assertRaisesRegex(ManifestError, "detector sha256 mismatch"):
            resolve_model_paths(path, load_pipeline_manifest(path))

    def test_classifier_failure_is_reported_as_optional_stage_error(self) -> None:
        payload = self.valid_payload()
        payload["classifier"]["file"] = (
            f"bread_classifier_yolov8n_cls_v1_{'0' * 64}.pt"
        )
        payload["classifier"]["sha256"] = "0" * 64
        path = self.write_manifest(payload)

        resolved = resolve_model_paths(path, load_pipeline_manifest(path))

        self.assertIsNone(resolved.classifier_path)
        self.assertIn(
            "classifier model does not exist", resolved.classifier_error or ""
        )

    def test_verifier_model_failure_is_reported_as_optional_stage_error(self) -> None:
        payload = self.valid_payload()
        payload["verifier"] = {
            "kind": "torchscript",
            "file": "missing-verifier.pt",
            "sha256": "0" * 64,
            "scoreThreshold": 0.7,
            "marginThreshold": 0.1,
        }
        path = self.write_manifest(payload)

        resolved = resolve_model_paths(path, load_pipeline_manifest(path))

        self.assertIsNone(resolved.verifier_path)
        self.assertIn("verifier model does not exist", resolved.verifier_error or "")

    def test_none_verifier_never_attempts_path_or_hash_resolution(self) -> None:
        path = self.write_manifest()
        manifest = load_pipeline_manifest(path)

        with patch(
            "tools.detectors.bread_pipeline_manifest.sha256_file",
            side_effect=lambda model_path: (
                self.detector_hash
                if model_path.name == "detector.pt"
                else self.classifier_hash
                if model_path.name == self.classifier_filename
                else self.fail("none verifier attempted hash resolution")
            ),
        ):
            resolved = resolve_model_paths(path, manifest)

        self.assertIsNone(resolved.verifier_path)
        self.assertIsNone(resolved.verifier_error)

    def test_rejects_non_schema_keys_and_json_types(self) -> None:
        cases = []
        extra = self.valid_payload()
        extra["unexpected"] = True
        cases.append((extra, "top-level fields"))
        boolean_schema = self.valid_payload()
        boolean_schema["schemaVersion"] = True
        cases.append((boolean_schema, "schemaVersion must be integer 1"))
        detector_key = self.valid_payload()
        detector_key["detector"]["extra"] = 1
        cases.append((detector_key, "detector fields"))
        boolean_imgsz = self.valid_payload()
        boolean_imgsz["classifier"]["imgsz"] = True
        cases.append((boolean_imgsz, "classifier imgsz"))
        wrong_float_type = self.valid_payload()
        wrong_float_type["quality"]["maxAreaRatio"] = 0
        cases.append((wrong_float_type, "maxAreaRatio must be JSON float 0.38"))

        for payload, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(ManifestError, message):
                    load_pipeline_manifest(self.write_manifest(payload))

    def test_rejects_invalid_thresholds_and_quality_settings(self) -> None:
        cases = []
        confidence = self.valid_payload()
        confidence["detector"]["confidence"] = 1.01
        cases.append((confidence, "detector confidence must be between 0 and 1"))
        precision = self.valid_payload()
        precision["classifier"]["oofPrecision"] = 0.939
        cases.append((precision, "precision is below the approved 0.94 floor"))
        quality = self.valid_payload()
        quality["quality"]["minBoxSize"] = 44
        cases.append((quality, "minBoxSize must be integer 45"))
        conservative = self.valid_payload()
        conservative["classifier"]["conservativeClasses"] = [10, 9]
        cases.append((conservative, "conservativeClasses"))

        for payload, message in cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(ManifestError, message):
                    load_pipeline_manifest(self.write_manifest(payload))

    def test_rejects_labels_and_non_content_addressed_classifier(self) -> None:
        wrong_label = self.valid_payload()
        wrong_label["labels"][15]["name"] = "Campagne"
        with self.assertRaisesRegex(ManifestError, "canonical category names"):
            load_pipeline_manifest(self.write_manifest(wrong_label))

        wrong_name = self.valid_payload()
        wrong_name["classifier"]["file"] = "classifier.pt"
        with self.assertRaisesRegex(
            ManifestError, "exact content-addressed sha256 name"
        ):
            load_pipeline_manifest(self.write_manifest(wrong_name))

    def test_rejects_model_paths_outside_manifest_directory(self) -> None:
        payload = self.valid_payload()
        payload["detector"]["file"] = "../detector.pt"

        with self.assertRaisesRegex(ManifestError, "local sibling filename"):
            load_pipeline_manifest(self.write_manifest(payload))

    def test_load_errors_are_manifest_errors(self) -> None:
        missing = self.root / "missing.json"
        with self.assertRaisesRegex(ManifestError, "could not read pipeline manifest"):
            load_pipeline_manifest(missing)

        invalid = self.root / "invalid.json"
        invalid.write_text("{", encoding="utf-8")
        with self.assertRaisesRegex(ManifestError, "could not read pipeline manifest"):
            load_pipeline_manifest(invalid)

    def test_current_product_manifest_and_models_are_valid(self) -> None:
        path = REPOSITORY_ROOT / "models" / "bread_pipeline_manifest.json"

        manifest = load_pipeline_manifest(path)
        resolved = resolve_model_paths(path, manifest)

        self.assertEqual(
            manifest.classifier["file"],
            f"bread_classifier_yolov8n_cls_v1_{manifest.classifier['sha256']}.pt",
        )
        self.assertIsNotNone(resolved.detector_path)
        self.assertIsNotNone(resolved.classifier_path)
        self.assertIsNone(resolved.classifier_error)
        self.assertIsNone(resolved.verifier_path)
        self.assertIsNone(resolved.verifier_error)


if __name__ == "__main__":
    unittest.main()
