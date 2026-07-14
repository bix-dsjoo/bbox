import copy
import json
import tempfile
import unittest
from dataclasses import FrozenInstanceError
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

from tools.bread_training.catalog import (
    CANONICAL_LABELS,
    build_catalog,
    normalize_category_name,
    write_catalog,
)


class CatalogTest(unittest.TestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        self.temp_root = Path(self.temp_directory.name)
        self.fixture_root = self.temp_root / "raw"
        self.fixture_root.mkdir()
        self._write_labels()

        for category_id, _ in CANONICAL_LABELS:
            directory = self.fixture_root / f"Bread{category_id:02d}"
            directory.mkdir()
            self._write_image(directory / f"single-{category_id:02d}.jpg")

        for directory_name in (
            "Test_20260706",
            "Test_20260708",
            "Test_20260710",
            "Test_20260714",
        ):
            self._write_mixed_fixture(directory_name)

        self.original_names = sorted(path.name for path in self.fixture_root.iterdir())

    def tearDown(self):
        self.temp_directory.cleanup()

    def _write_labels(self, labels=CANONICAL_LABELS):
        content = "\n".join(f"{category_id}. {name}" for category_id, name in labels)
        (self.fixture_root / "labels.txt").write_text(content + "\n", encoding="utf-8")

    def _write_image(self, path: Path):
        pixels = np.full((3, 4, 3), 127, dtype=np.uint8)
        success, encoded = cv2.imencode(".jpg", pixels)
        self.assertTrue(success)
        path.write_bytes(encoded.tobytes())

    def _write_exif_oriented_image(self, path: Path):
        pixels = np.full((3, 4, 3), 127, dtype=np.uint8)
        exif = Image.Exif()
        exif[274] = 6
        Image.fromarray(pixels).save(path, exif=exif)

    def _write_mixed_fixture(self, directory_name: str):
        directory = self.fixture_root / directory_name
        directory.mkdir()
        image_name = "E0501.jpg"
        self._write_image(directory / image_name)
        categories = [
            {
                "id": category_id,
                "name": "Grain  Campagne" if category_id == 16 else name,
                "supercategory": "object",
            }
            for category_id, name in CANONICAL_LABELS
        ]
        payload = {
            "images": [{"id": 1, "file_name": image_name, "width": 4, "height": 3}],
            "annotations": [
                {
                    "id": 1,
                    "image_id": 1,
                    "category_id": 16,
                    "bbox": [0.25, 0.5, 2.0, 1.5],
                    "area": 3.0,
                    "iscrowd": 0,
                }
            ],
            "categories": categories,
        }
        (directory / f"{directory_name}.json").write_text(
            json.dumps(payload), encoding="utf-8"
        )

    def _assert_malformed_coco_payload_rejected(self, payload):
        json_path = self.fixture_root / "Test_20260714" / "Test_20260714.json"
        json_path.write_text(json.dumps(payload), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "JSON integer"):
            build_catalog(self.fixture_root)

    def _empty_all_source_directories(self):
        for directory in self.fixture_root.glob("Bread[0-9][0-9]"):
            for image_path in directory.iterdir():
                image_path.unlink()
        for directory_name in (
            "Test_20260706",
            "Test_20260708",
            "Test_20260710",
            "Test_20260714",
        ):
            directory = self.fixture_root / directory_name
            for image_path in directory.glob("*.jpg"):
                image_path.unlink()
            json_path = directory / f"{directory_name}.json"
            payload = json.loads(json_path.read_text(encoding="utf-8"))
            payload["images"] = []
            payload["annotations"] = []
            json_path.write_text(json.dumps(payload), encoding="utf-8")

    def test_normalizes_grain_campagne_alias(self):
        self.assertEqual(normalize_category_name("Grain  Campagne"), "Grain Campagne")

    def test_mixed_key_includes_date_directory(self):
        catalog = build_catalog(self.fixture_root)
        keys = {image.key for image in catalog.images if image.source_kind == "mixed_scene"}
        self.assertIn("Test_20260714/E0501.jpg", keys)

    def test_catalog_never_writes_under_raw_root(self):
        catalog = build_catalog(self.fixture_root)
        output = self.temp_root / "derived" / "catalog.json"

        write_catalog(catalog, output)

        self.assertTrue(output.is_file())
        self.assertEqual(
            sorted(path.name for path in self.fixture_root.iterdir()), self.original_names
        )

    def test_write_catalog_rejects_output_under_raw_root(self):
        catalog = build_catalog(self.fixture_root)

        with self.assertRaisesRegex(ValueError, "raw root"):
            write_catalog(catalog, self.fixture_root / "catalog.json")

        self.assertFalse((self.fixture_root / "catalog.json").exists())

    def test_catalog_retains_resolved_raw_root(self):
        catalog = build_catalog(self.fixture_root)

        self.assertEqual(
            getattr(catalog, "raw_root", None), str(self.fixture_root.resolve())
        )

    def test_catalog_json_includes_resolved_raw_root(self):
        payload = build_catalog(self.fixture_root).to_json()

        self.assertEqual(payload.get("raw_root"), str(self.fixture_root.resolve()))

    def test_empty_catalog_rejects_output_under_raw_root(self):
        self._empty_all_source_directories()
        catalog = build_catalog(self.fixture_root)
        output = self.fixture_root / "catalog.json"

        self.assertEqual(catalog.images, ())
        with self.assertRaisesRegex(ValueError, "raw root"):
            write_catalog(catalog, output)
        self.assertFalse(output.exists())

    def test_catalog_uses_canonical_labels_and_namespaced_annotation_ids(self):
        catalog = build_catalog(self.fixture_root)

        self.assertEqual(catalog.labels, CANONICAL_LABELS)
        self.assertEqual(len(catalog.images), 24)
        self.assertEqual(len(catalog.annotations), 4)
        self.assertEqual(
            {annotation.category_name for annotation in catalog.annotations},
            {"Grain Campagne"},
        )
        self.assertEqual(
            {annotation.annotation_id for annotation in catalog.annotations},
            {
                "Test_20260706:1",
                "Test_20260708:1",
                "Test_20260710:1",
                "Test_20260714:1",
            },
        )

    def test_catalog_records_decoded_dimensions_and_is_immutable(self):
        catalog = build_catalog(self.fixture_root)
        image = next(item for item in catalog.images if item.key == "Bread01/single-01.jpg")

        self.assertEqual((image.width, image.height), (4, 3))
        self.assertEqual(len(image.sha256), 64)
        with self.assertRaises(FrozenInstanceError):
            image.width = 99

    def test_catalog_image_category_metadata_matches_source_kind(self):
        catalog = build_catalog(self.fixture_root)
        bread01 = next(image for image in catalog.images if image.source_group == "Bread01")
        bread20 = next(image for image in catalog.images if image.source_group == "Bread20")
        mixed = next(image for image in catalog.images if image.source_kind == "mixed_scene")

        self.assertEqual(
            (getattr(bread01, "category_id", None), getattr(bread01, "category_name", None)),
            (1, "Walnut Donut"),
        )
        self.assertEqual(
            (getattr(bread20, "category_id", None), getattr(bread20, "category_name", None)),
            (20, "Plain Bread"),
        )
        self.assertEqual(
            (getattr(mixed, "category_id", "missing"), getattr(mixed, "category_name", "missing")),
            (None, None),
        )

    def test_catalog_json_includes_image_category_metadata(self):
        images = build_catalog(self.fixture_root).to_json()["images"]
        bread01 = next(image for image in images if image["source_group"] == "Bread01")
        mixed = next(image for image in images if image["source_kind"] == "mixed_scene")

        self.assertEqual(
            (bread01.get("category_id"), bread01.get("category_name")),
            (1, "Walnut Donut"),
        )
        self.assertIn("category_id", mixed)
        self.assertIn("category_name", mixed)
        self.assertIsNone(mixed["category_id"])
        self.assertIsNone(mixed["category_name"])

    def test_catalog_dimensions_respect_exif_orientation(self):
        directory = self.fixture_root / "Test_20260714"
        self._write_exif_oriented_image(directory / "E0501.jpg")
        json_path = directory / "Test_20260714.json"
        payload = json.loads(json_path.read_text(encoding="utf-8"))
        payload["images"][0]["width"] = 3
        payload["images"][0]["height"] = 4
        json_path.write_text(json.dumps(payload), encoding="utf-8")

        catalog = build_catalog(self.fixture_root)

        image = next(
            item for item in catalog.images if item.key == "Test_20260714/E0501.jpg"
        )
        self.assertEqual((image.width, image.height), (3, 4))

    def test_to_json_uses_plain_serializable_values(self):
        payload = build_catalog(self.fixture_root).to_json()

        self.assertEqual(payload["labels"][15], {"id": 16, "name": "Grain Campagne"})
        self.assertIsInstance(payload["images"][0], dict)
        self.assertIsInstance(payload["annotations"][0]["bbox"], list)
        json.dumps(payload)

    def test_rejects_noncanonical_labels_registry(self):
        labels = list(CANONICAL_LABELS)
        labels[0] = (1, "Changed Name")
        self._write_labels(labels)

        with self.assertRaisesRegex(ValueError, "labels.txt"):
            build_catalog(self.fixture_root)

    def test_rejects_noncanonical_coco_category(self):
        json_path = self.fixture_root / "Test_20260714" / "Test_20260714.json"
        payload = json.loads(json_path.read_text(encoding="utf-8"))
        payload["categories"][0]["name"] = "Changed Name"
        json_path.write_text(json.dumps(payload), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "category registry"):
            build_catalog(self.fixture_root)

    def test_rejects_noninteger_coco_category_registry_ids(self):
        json_path = self.fixture_root / "Test_20260714" / "Test_20260714.json"
        original = json.loads(json_path.read_text(encoding="utf-8"))

        for invalid_id in (1.5, True, "1"):
            with self.subTest(invalid_id=invalid_id):
                payload = copy.deepcopy(original)
                payload["categories"][0]["id"] = invalid_id
                self._assert_malformed_coco_payload_rejected(payload)

    def test_rejects_noninteger_coco_image_ids(self):
        json_path = self.fixture_root / "Test_20260714" / "Test_20260714.json"
        original = json.loads(json_path.read_text(encoding="utf-8"))

        for invalid_id in (1.5, True, "1"):
            with self.subTest(invalid_id=invalid_id):
                payload = copy.deepcopy(original)
                payload["images"][0]["id"] = invalid_id
                self._assert_malformed_coco_payload_rejected(payload)

    def test_rejects_noninteger_coco_annotation_ids_and_references(self):
        json_path = self.fixture_root / "Test_20260714" / "Test_20260714.json"
        original = json.loads(json_path.read_text(encoding="utf-8"))

        for field_name in ("id", "image_id", "category_id"):
            for invalid_id in (1.5, True, "1"):
                with self.subTest(field_name=field_name, invalid_id=invalid_id):
                    payload = copy.deepcopy(original)
                    payload["annotations"][0][field_name] = invalid_id
                    self._assert_malformed_coco_payload_rejected(payload)

    def test_rejects_missing_bread_folder(self):
        directory = self.fixture_root / "Bread20"
        next(directory.iterdir()).unlink()
        directory.rmdir()

        with self.assertRaisesRegex(ValueError, "Bread20"):
            build_catalog(self.fixture_root)

    def test_rejects_bread_suffix_outside_canonical_range(self):
        (self.fixture_root / "Bread21").mkdir()

        with self.assertRaisesRegex(ValueError, "Bread21"):
            build_catalog(self.fixture_root)


if __name__ == "__main__":
    unittest.main()
