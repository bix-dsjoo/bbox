import hashlib
import json
import os
import shutil
import tempfile
import unittest
from dataclasses import FrozenInstanceError
from pathlib import Path
from unittest.mock import patch

from tools.bread_training.detector_data import (
    build_detector_all_data,
    build_detector_fold_dataset,
    coco_xywh_to_yolo,
)


def _fixture(root: Path, count: int = 5):
    images = []
    annotations = []
    assignments = {}
    for index in range(count):
        key = f"Test/example_{index}.jpg"
        source = root / f"example_{index}.jpg"
        source.write_bytes(f"image-{index}".encode())
        images.append(
            {
                "key": key,
                "absolute_path": str(source),
                "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                "width": 100,
                "height": 80,
                "source_kind": "mixed_scene",
                "source_group": "Test",
                "category_id": None,
                "category_name": None,
            }
        )
        annotations.append(
            {
                "annotation_id": f"Test:{index + 1}",
                "image_key": key,
                "category_id": 1,
                "category_name": "Bread",
                "bbox": [10, 20, 30, 20],
            }
        )
        assignments[key] = index % 5
    catalog = {
        "raw_root": str(root),
        "labels": [{"id": 1, "name": "Bread"}],
        "images": images,
        "annotations": annotations,
    }
    split = {"folds": 5, "mixed_assignments": assignments}
    return catalog, split


class DetectorDataTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.raw = self.root / "raw"
        self.output = self.root / "datasets"
        self.raw.mkdir()

    def tearDown(self):
        self.temporary_directory.cleanup()

    def test_detector_fold_has_disjoint_train_val_test_keys(self):
        catalog, split = _fixture(self.raw)
        manifest = build_detector_fold_dataset(catalog, split, 2, self.output)

        self.assertEqual(manifest.heldout_fold, 2)
        self.assertEqual(manifest.validation_fold, 3)
        self.assertFalse(set(manifest.train_keys) & set(manifest.validation_keys))
        self.assertFalse(set(manifest.train_keys) & set(manifest.test_keys))
        self.assertFalse(set(manifest.validation_keys) & set(manifest.test_keys))
        with self.assertRaises(FrozenInstanceError):
            manifest.heldout_fold = 4

    def test_coco_xywh_is_written_as_normalized_one_class_yolo(self):
        catalog, split = _fixture(self.raw)
        manifest = build_detector_fold_dataset(catalog, split, 0, self.output)

        label = next((manifest.dataset_root / "labels" / "train").rglob("*.txt"))
        self.assertEqual(
            label.read_text(encoding="utf-8").strip(),
            "0 0.25000000 0.37500000 0.30000000 0.25000000",
        )
        self.assertEqual(
            coco_xywh_to_yolo((10, 20, 30, 20), 100, 80),
            (0, 0.25, 0.375, 0.3, 0.25),
        )

    def test_each_mixed_image_is_test_once_across_five_manifests(self):
        catalog, split = _fixture(self.raw, 83)
        manifests = [
            build_detector_fold_dataset(catalog, split, fold, self.output)
            for fold in range(5)
        ]

        keys = [key for item in manifests for key in item.test_keys]
        self.assertEqual(
            [len(item.test_keys) for item in manifests], [17, 17, 17, 16, 16]
        )
        self.assertEqual(len(keys), 83)
        self.assertEqual(len(set(keys)), 83)

    def test_source_manifest_records_hash_fold_and_annotation_ids(self):
        catalog, split = _fixture(self.raw)
        manifest = build_detector_fold_dataset(catalog, split, 0, self.output)

        payload = json.loads(
            (manifest.dataset_root / "source_manifest.json").read_text(encoding="utf-8")
        )
        test_record = payload["splits"]["test"][0]
        self.assertEqual(test_record["image_key"], "Test/example_0.jpg")
        self.assertEqual(
            test_record["sha256"], hashlib.sha256(b"image-0").hexdigest()
        )
        self.assertEqual(test_record["source_fold"], 0)
        self.assertEqual(test_record["annotation_ids"], ["Test:1"])
        yaml_text = manifest.dataset_yaml.read_text(encoding="utf-8")
        self.assertIn(
            f"train: {(manifest.dataset_root / 'images' / 'train').resolve()}",
            yaml_text,
        )
        self.assertIn(
            f"val: {(manifest.dataset_root / 'images' / 'val').resolve()}",
            yaml_text,
        )
        self.assertIn("names: [bread]", yaml_text)

    def test_out_of_bounds_bbox_fails_before_dataset_is_published(self):
        catalog, split = _fixture(self.raw)
        catalog["annotations"][0]["bbox"] = [90, 20, 30, 20]

        with self.assertRaisesRegex(ValueError, "outside image bounds"):
            build_detector_fold_dataset(catalog, split, 0, self.output)

        self.assertFalse((self.output / "fold_0").exists())

    def test_catalog_and_assignment_key_mismatch_fails_closed(self):
        catalog, split = _fixture(self.raw)
        split["mixed_assignments"]["Test/missing.jpg"] = 0

        with self.assertRaisesRegex(ValueError, "must match"):
            build_detector_fold_dataset(catalog, split, 0, self.output)

    def test_windows_rooted_image_key_cannot_escape_dataset(self):
        catalog, split = _fixture(self.raw)
        original = catalog["images"][0]["key"]
        escaped = r"\escaped\image.jpg"
        catalog["images"][0]["key"] = escaped
        catalog["annotations"][0]["image_key"] = escaped
        split["mixed_assignments"][escaped] = split["mixed_assignments"].pop(original)

        with self.assertRaisesRegex(ValueError, "unsafe catalog image key"):
            build_detector_fold_dataset(catalog, split, 0, self.output)

    def test_catalog_hash_must_match_source_bytes(self):
        catalog, split = _fixture(self.raw)
        catalog["images"][0]["sha256"] = "0" * 64

        with self.assertRaisesRegex(ValueError, "sha256 does not match"):
            build_detector_fold_dataset(catalog, split, 0, self.output)

    def test_images_with_same_stem_cannot_share_a_label_path(self):
        catalog, split = _fixture(self.raw)
        first_key = catalog["images"][0]["key"]
        second_key = catalog["images"][1]["key"]
        png_source = self.raw / "shared.png"
        png_source.write_bytes((self.raw / "example_1.jpg").read_bytes())
        catalog["images"][0]["key"] = "Test/shared.jpg"
        catalog["images"][1].update(
            {
                "key": "Test/shared.png",
                "absolute_path": str(png_source),
                "sha256": hashlib.sha256(png_source.read_bytes()).hexdigest(),
            }
        )
        catalog["annotations"][0]["image_key"] = "Test/shared.jpg"
        catalog["annotations"][1]["image_key"] = "Test/shared.png"
        split["mixed_assignments"]["Test/shared.jpg"] = split[
            "mixed_assignments"
        ].pop(first_key)
        split["mixed_assignments"]["Test/shared.png"] = split[
            "mixed_assignments"
        ].pop(second_key)

        with self.assertRaisesRegex(ValueError, "label paths overlap"):
            build_detector_fold_dataset(catalog, split, 0, self.output)

    def test_materialized_images_are_independent_copies_of_raw_sources(self):
        catalog, split = _fixture(self.raw)
        manifest = build_detector_fold_dataset(catalog, split, 0, self.output)

        copied = next((manifest.dataset_root / "images" / "test").rglob("*.jpg"))
        self.assertEqual(copied.read_bytes(), b"image-0")
        self.assertFalse(os.path.samefile(copied, self.raw / "example_0.jpg"))
        copied.write_bytes(b"downstream-write")
        self.assertEqual((self.raw / "example_0.jpg").read_bytes(), b"image-0")

    def test_failed_fold_replacement_restores_previous_dataset(self):
        catalog, split = _fixture(self.raw)
        manifest = build_detector_fold_dataset(catalog, split, 0, self.output)
        marker = manifest.dataset_root / "previous-success.marker"
        marker.write_text("preserve", encoding="utf-8")
        real_replace = os.replace

        def fail_staging_publish(source, destination):
            source = Path(source)
            destination = Path(destination)
            if (
                source.name.startswith(".fold_0-staging-")
                and destination.name == "fold_0"
            ):
                raise PermissionError("injected publish lock")
            return real_replace(source, destination)

        with patch(
            "tools.bread_training.detector_data.os.replace",
            side_effect=fail_staging_publish,
        ):
            with self.assertRaisesRegex(PermissionError, "injected publish lock"):
                build_detector_fold_dataset(catalog, split, 0, self.output)

        self.assertEqual(marker.read_text(encoding="utf-8"), "preserve")
        self.assertTrue(manifest.dataset_yaml.is_file())
        self.assertEqual(list(self.output.glob(".fold_0-staging-*")), [])
        self.assertFalse((self.output / ".fold_0.publish-backup").exists())
        self.assertFalse((self.output / ".fold_0.publish-cleanup.json").exists())

    def test_failed_initial_fold_publish_leaves_no_partial_artifacts(self):
        catalog, split = _fixture(self.raw)

        with patch(
            "tools.bread_training.detector_data.os.replace",
            side_effect=PermissionError("injected initial publish lock"),
        ):
            with self.assertRaisesRegex(PermissionError, "initial publish lock"):
                build_detector_fold_dataset(catalog, split, 0, self.output)

        self.assertFalse((self.output / "fold_0").exists())
        self.assertEqual(list(self.output.glob(".fold_0-staging-*")), [])
        self.assertFalse((self.output / ".fold_0.publish-backup").exists())
        self.assertFalse((self.output / ".fold_0.publish-cleanup.json").exists())

    def test_partial_fold_backup_cleanup_keeps_new_dataset_active(self):
        catalog, split = _fixture(self.raw)
        manifest = build_detector_fold_dataset(catalog, split, 0, self.output)
        marker = manifest.dataset_root / "previous-success.marker"
        marker.write_text("preserve", encoding="utf-8")
        real_rmtree = shutil.rmtree

        def fail_backup_cleanup(path, *args, **kwargs):
            path = Path(path)
            if "publish-backup" in path.name:
                old_marker = path / "previous-success.marker"
                if old_marker.exists():
                    old_marker.unlink()
                raise PermissionError("injected partial retirement cleanup lock")
            return real_rmtree(path, *args, **kwargs)

        with patch(
            "tools.bread_training.detector_data.shutil.rmtree",
            side_effect=fail_backup_cleanup,
        ):
            replacement = build_detector_fold_dataset(
                catalog, split, 0, self.output
            )

        self.assertFalse(marker.exists())
        self.assertTrue(replacement.dataset_yaml.is_file())
        self.assertTrue((replacement.dataset_root / "source_manifest.json").is_file())
        self.assertEqual(list(self.output.glob(".fold_0-staging-*")), [])
        self.assertTrue((self.output / ".fold_0.publish-backup").is_dir())
        self.assertTrue(
            (self.output / ".fold_0.publish-cleanup.json").is_file()
        )

        rebuilt = build_detector_fold_dataset(catalog, split, 0, self.output)
        self.assertTrue(rebuilt.dataset_yaml.is_file())
        self.assertFalse((self.output / ".fold_0.publish-backup").exists())
        self.assertFalse((self.output / ".fold_0.publish-cleanup.json").exists())

    def test_next_fold_build_consumes_pending_backup_cleanup_marker(self):
        catalog, split = _fixture(self.raw)
        manifest = build_detector_fold_dataset(catalog, split, 0, self.output)
        (manifest.dataset_root / "previous-success.marker").write_text(
            "preserve", encoding="utf-8"
        )
        real_rmtree = shutil.rmtree

        def fail_backup_cleanup(path, *args, **kwargs):
            path = Path(path)
            if "publish-backup" in path.name:
                marker = path / "previous-success.marker"
                if marker.exists():
                    marker.unlink()
                raise PermissionError("injected partial backup cleanup lock")
            return real_rmtree(path, *args, **kwargs)

        with patch(
            "tools.bread_training.detector_data.shutil.rmtree",
            side_effect=fail_backup_cleanup,
        ):
            replacement = build_detector_fold_dataset(
                catalog, split, 0, self.output
            )

        pending = json.loads(
            (self.output / ".fold_0.publish-cleanup.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(pending["destination_name"], "fold_0")
        self.assertNotIn("cleanup_path", pending)
        self.assertTrue((self.output / ".fold_0.publish-backup").is_dir())

        rebuilt = build_detector_fold_dataset(catalog, split, 0, self.output)
        self.assertTrue(rebuilt.dataset_yaml.is_file())
        self.assertFalse((self.output / ".fold_0.publish-backup").exists())
        self.assertFalse((self.output / ".fold_0.publish-cleanup.json").exists())

    def test_fold_publish_never_allocates_a_post_commit_retired_path(self):
        catalog, split = _fixture(self.raw)
        build_detector_fold_dataset(catalog, split, 0, self.output)
        replacement = build_detector_fold_dataset(
            catalog, split, 0, self.output
        )

        self.assertTrue(replacement.dataset_yaml.is_file())
        self.assertEqual(list(self.output.glob("*retired*")), [])
        self.assertFalse((self.output / ".fold_0.publish-backup").exists())
        self.assertFalse((self.output / ".fold_0.publish-cleanup.json").exists())

    def test_all_data_builder_writes_every_real_image_and_annotation(self):
        catalog, _ = _fixture(self.raw)
        dataset_root = build_detector_all_data(catalog, self.output)

        self.assertEqual(
            len(list((dataset_root / "images" / "train").rglob("*.jpg"))), 5
        )
        self.assertEqual(
            len(list((dataset_root / "labels" / "train").rglob("*.txt"))), 5
        )
        records = json.loads(
            (dataset_root / "source_manifest.json").read_text(encoding="utf-8")
        )["splits"]["train"]
        self.assertEqual(sum(len(item["annotation_ids"]) for item in records), 5)

    def test_all_data_builder_preserves_fold_datasets_in_same_output_root(self):
        catalog, split = _fixture(self.raw)
        fold = build_detector_fold_dataset(catalog, split, 0, self.output)

        dataset_root = build_detector_all_data(catalog, self.output)

        self.assertEqual(dataset_root, self.output.resolve() / "all_data")
        self.assertTrue(fold.dataset_yaml.is_file())

    def test_failed_all_data_replacement_restores_previous_dataset(self):
        catalog, _ = _fixture(self.raw)
        dataset_root = build_detector_all_data(catalog, self.output)
        marker = dataset_root / "previous-success.marker"
        marker.write_text("preserve", encoding="utf-8")
        real_replace = os.replace

        def fail_staging_publish(source, destination):
            source = Path(source)
            destination = Path(destination)
            if (
                source.name.startswith(".all_data-staging-")
                and destination.name == "all_data"
            ):
                raise PermissionError("injected all-data publish lock")
            return real_replace(source, destination)

        with patch(
            "tools.bread_training.detector_data.os.replace",
            side_effect=fail_staging_publish,
        ):
            with self.assertRaisesRegex(PermissionError, "all-data publish lock"):
                build_detector_all_data(catalog, self.output)

        self.assertEqual(marker.read_text(encoding="utf-8"), "preserve")
        self.assertTrue((dataset_root / "dataset.yaml").is_file())
        self.assertEqual(list(self.output.glob(".all_data-staging-*")), [])
        self.assertFalse((self.output / ".all_data.publish-backup").exists())
        self.assertFalse((self.output / ".all_data.publish-cleanup.json").exists())

    def test_partial_all_data_backup_cleanup_keeps_new_dataset_active(self):
        catalog, _ = _fixture(self.raw)
        dataset_root = build_detector_all_data(catalog, self.output)
        marker = dataset_root / "previous-success.marker"
        marker.write_text("preserve", encoding="utf-8")
        real_rmtree = shutil.rmtree

        def fail_backup_cleanup(path, *args, **kwargs):
            path = Path(path)
            if "publish-backup" in path.name:
                old_marker = path / "previous-success.marker"
                if old_marker.exists():
                    old_marker.unlink()
                raise PermissionError(
                    "injected partial all-data retirement cleanup lock"
                )
            return real_rmtree(path, *args, **kwargs)

        with patch(
            "tools.bread_training.detector_data.shutil.rmtree",
            side_effect=fail_backup_cleanup,
        ):
            replacement = build_detector_all_data(catalog, self.output)

        self.assertFalse(marker.exists())
        self.assertTrue((replacement / "dataset.yaml").is_file())
        self.assertTrue((replacement / "source_manifest.json").is_file())
        self.assertEqual(list(self.output.glob(".all_data-staging-*")), [])
        self.assertTrue((self.output / ".all_data.publish-backup").is_dir())
        self.assertTrue(
            (self.output / ".all_data.publish-cleanup.json").is_file()
        )

        rebuilt = build_detector_all_data(catalog, self.output)
        self.assertTrue((rebuilt / "dataset.yaml").is_file())
        self.assertFalse((self.output / ".all_data.publish-backup").exists())
        self.assertFalse((self.output / ".all_data.publish-cleanup.json").exists())

    def test_next_all_data_build_consumes_pending_backup_cleanup_marker(self):
        catalog, _ = _fixture(self.raw)
        dataset_root = build_detector_all_data(catalog, self.output)
        (dataset_root / "previous-success.marker").write_text(
            "preserve", encoding="utf-8"
        )
        real_rmtree = shutil.rmtree

        def fail_backup_cleanup(path, *args, **kwargs):
            path = Path(path)
            if "publish-backup" in path.name:
                marker = path / "previous-success.marker"
                if marker.exists():
                    marker.unlink()
                raise PermissionError(
                    "injected partial all-data backup cleanup lock"
                )
            return real_rmtree(path, *args, **kwargs)

        with patch(
            "tools.bread_training.detector_data.shutil.rmtree",
            side_effect=fail_backup_cleanup,
        ):
            replacement = build_detector_all_data(catalog, self.output)

        pending = json.loads(
            (self.output / ".all_data.publish-cleanup.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(pending["destination_name"], "all_data")
        self.assertNotIn("cleanup_path", pending)
        self.assertTrue((self.output / ".all_data.publish-backup").is_dir())

        rebuilt = build_detector_all_data(catalog, self.output)
        self.assertTrue((rebuilt / "dataset.yaml").is_file())
        self.assertFalse((self.output / ".all_data.publish-backup").exists())
        self.assertFalse((self.output / ".all_data.publish-cleanup.json").exists())

    def test_all_data_publish_never_allocates_a_post_commit_retired_path(self):
        catalog, _ = _fixture(self.raw)
        build_detector_all_data(catalog, self.output)
        replacement = build_detector_all_data(catalog, self.output)

        self.assertTrue((replacement / "dataset.yaml").is_file())
        self.assertEqual(list(self.output.glob("*retired*")), [])
        self.assertFalse((self.output / ".all_data.publish-backup").exists())
        self.assertFalse((self.output / ".all_data.publish-cleanup.json").exists())

    def test_all_data_builder_refuses_to_replace_unrelated_directory(self):
        catalog, _ = _fixture(self.raw)
        unrelated = self.output / "all_data"
        unrelated.mkdir(parents=True)
        marker = unrelated / "keep.txt"
        marker.write_text("unrelated", encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "not a generated detector dataset"):
            build_detector_all_data(catalog, self.output)

        self.assertEqual(marker.read_text(encoding="utf-8"), "unrelated")

    def test_fold_marker_write_failure_preserves_previous_dataset(self):
        catalog, split = _fixture(self.raw)
        manifest = build_detector_fold_dataset(catalog, split, 0, self.output)
        old_marker = manifest.dataset_root / "previous-success.marker"
        old_marker.write_text("preserve", encoding="utf-8")
        transaction_marker = self.output / ".fold_0.publish-cleanup.json"
        marker_temporary = self.output / ".fold_0.publish-cleanup.json.tmp"
        real_write_text = Path.write_text

        def fail_transaction_marker(path, data, *args, **kwargs):
            if path == marker_temporary:
                raise PermissionError("injected marker write lock")
            return real_write_text(path, data, *args, **kwargs)

        with patch.object(Path, "write_text", new=fail_transaction_marker):
            with self.assertRaisesRegex(PermissionError, "marker write lock"):
                build_detector_fold_dataset(catalog, split, 0, self.output)

        self.assertEqual(old_marker.read_text(encoding="utf-8"), "preserve")
        self.assertFalse((self.output / ".fold_0.publish-backup").exists())
        self.assertFalse(transaction_marker.exists())

    def test_all_data_marker_write_failure_preserves_previous_dataset(self):
        catalog, _ = _fixture(self.raw)
        dataset_root = build_detector_all_data(catalog, self.output)
        old_marker = dataset_root / "previous-success.marker"
        old_marker.write_text("preserve", encoding="utf-8")
        transaction_marker = self.output / ".all_data.publish-cleanup.json"
        marker_temporary = self.output / ".all_data.publish-cleanup.json.tmp"
        real_write_text = Path.write_text

        def fail_transaction_marker(path, data, *args, **kwargs):
            if path == marker_temporary:
                raise PermissionError("injected all-data marker write lock")
            return real_write_text(path, data, *args, **kwargs)

        with patch.object(Path, "write_text", new=fail_transaction_marker):
            with self.assertRaisesRegex(PermissionError, "marker write lock"):
                build_detector_all_data(catalog, self.output)

        self.assertEqual(old_marker.read_text(encoding="utf-8"), "preserve")
        self.assertFalse((self.output / ".all_data.publish-backup").exists())
        self.assertFalse(transaction_marker.exists())

    def test_deterministic_backup_without_owned_marker_is_refused(self):
        catalog, split = _fixture(self.raw)
        build_detector_fold_dataset(catalog, split, 0, self.output)
        unowned_backup = self.output / ".fold_0.publish-backup"
        unowned_backup.mkdir()
        sentinel = unowned_backup / "unowned.txt"
        sentinel.write_text("preserve", encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "backup exists without"):
            build_detector_fold_dataset(catalog, split, 0, self.output)

        self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")

    def test_marker_cannot_redirect_cleanup_to_prefix_shaped_sibling(self):
        catalog, split = _fixture(self.raw)
        build_detector_fold_dataset(catalog, split, 0, self.output)
        injected = self.output / ".fold_0.publish-backup-evil"
        injected.mkdir()
        sentinel = injected / "keep.txt"
        sentinel.write_text("preserve", encoding="utf-8")
        transaction_marker = self.output / ".fold_0.publish-cleanup.json"
        transaction_marker.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "destination_name": "fold_0",
                    "dataset_kind": "fold",
                    "cleanup_path": injected.name,
                }
            ),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(ValueError, "does not own destination"):
            build_detector_fold_dataset(catalog, split, 0, self.output)

        self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")
        self.assertTrue(transaction_marker.exists())


if __name__ == "__main__":
    unittest.main()
