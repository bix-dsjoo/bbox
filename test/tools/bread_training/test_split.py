import json
import tempfile
import unittest
from collections import Counter, defaultdict
from pathlib import Path
from types import SimpleNamespace

import cv2
import numpy as np

from tools.bread_training.catalog import Catalog, CatalogAnnotation, CatalogImage
from tools.bread_training.split import (
    DerivedRecord,
    LeakageError,
    SplitError,
    assert_no_mixed_scene_leakage,
    assign_folds,
    assign_single_product_folds,
    group_single_product_images,
    load_catalog,
    main,
)


LABELS = tuple((category_id, f"Label {category_id}") for category_id in range(1, 7))
DATE_GROUPS = (
    "Test_20260706",
    "Test_20260708",
    "Test_20260710",
    "Test_20260714",
)


def catalog_with_83_mixed_images(reverse=False):
    images = []
    annotations = []
    for index in range(83):
        source_group = DATE_GROUPS[index % len(DATE_GROUPS)]
        key = f"{source_group}/E{index:04d}.jpg"
        images.append(
            CatalogImage(
                key=key,
                absolute_path=f"C:/raw/{key}",
                sha256=f"{index:064x}",
                width=640,
                height=480,
                source_kind="mixed_scene",
                source_group=source_group,
            )
        )
        category_ids = {1 + index % 5, 6 if index % 2 == 0 else 1}
        for category_id in sorted(category_ids):
            annotations.append(
                CatalogAnnotation(
                    annotation_id=f"{source_group}:{index}:{category_id}",
                    image_key=key,
                    category_id=category_id,
                    category_name=dict(LABELS)[category_id],
                    bbox=(10.0 * category_id, 10.0, 20.0, 20.0),
                )
            )
    if reverse:
        images.reverse()
        annotations.reverse()
    return Catalog(
        labels=LABELS,
        images=tuple(images),
        annotations=tuple(annotations),
        raw_root="C:/raw",
    )


class FoldAssignmentTest(unittest.TestCase):
    def test_fold_sizes_and_unique_oof_assignment(self):
        assignments = assign_folds(
            catalog_with_83_mixed_images(), folds=5, seed=20260714
        )

        counts = sorted(Counter(assignments.values()).values(), reverse=True)
        self.assertEqual(counts, [17, 17, 17, 16, 16])
        self.assertEqual(len(assignments), 83)
        self.assertEqual(set(assignments.values()), set(range(5)))

    def test_assignment_is_deterministic_independent_of_catalog_order(self):
        forward = assign_folds(catalog_with_83_mixed_images(), seed=20260714)
        reverse = assign_folds(
            catalog_with_83_mixed_images(reverse=True), seed=20260714
        )

        self.assertEqual(forward, reverse)

    def test_each_date_group_is_balanced_across_folds(self):
        catalog = catalog_with_83_mixed_images()
        assignments = assign_folds(catalog, seed=20260714)
        counts = defaultdict(Counter)
        for image in catalog.images:
            counts[image.source_group][assignments[image.key]] += 1

        for date_counts in counts.values():
            self.assertLessEqual(max(date_counts.values()) - min(date_counts.values()), 1)

    def test_multilabel_distribution_is_balanced(self):
        catalog = catalog_with_83_mixed_images()
        assignments = assign_folds(catalog, seed=20260714)
        image_labels = defaultdict(set)
        for annotation in catalog.annotations:
            image_labels[annotation.image_key].add(annotation.category_id)

        label_counts = defaultdict(Counter)
        for key, labels in image_labels.items():
            for label in labels:
                label_counts[label][assignments[key]] += 1

        for counts in label_counts.values():
            values = [counts[fold] for fold in range(5)]
            self.assertLessEqual(max(values) - min(values), 2)

    def test_no_same_date_swap_can_improve_label_balance(self):
        catalog = catalog_with_83_mixed_images()
        assignments = assign_folds(catalog, seed=20260714)
        image_by_key = {image.key: image for image in catalog.images}
        labels_by_key = defaultdict(set)
        for annotation in catalog.annotations:
            labels_by_key[annotation.image_key].add(annotation.category_id)
        counts = {fold: Counter() for fold in range(5)}
        for key, fold in assignments.items():
            counts[fold].update(labels_by_key[key])

        for left in sorted(assignments):
            for right in sorted(assignments):
                left_fold = assignments[left]
                right_fold = assignments[right]
                if left >= right or left_fold == right_fold:
                    continue
                if image_by_key[left].source_group != image_by_key[right].source_group:
                    continue
                labels = labels_by_key[left] | labels_by_key[right]
                before = sum(
                    counts[left_fold][label] ** 2 + counts[right_fold][label] ** 2
                    for label in labels
                )
                after = sum(
                    (counts[left_fold][label] - (label in labels_by_key[left]) + (label in labels_by_key[right])) ** 2
                    + (counts[right_fold][label] - (label in labels_by_key[right]) + (label in labels_by_key[left])) ** 2
                    for label in labels
                )
                self.assertGreaterEqual(after, before, (left, right))

    def test_assignment_fails_closed_for_unexpected_shape(self):
        catalog = catalog_with_83_mixed_images()

        with self.assertRaises(SplitError):
            assign_folds(catalog, folds=4, seed=20260714)
        with self.assertRaises(SplitError):
            assign_folds(
                Catalog(
                    labels=catalog.labels,
                    images=catalog.images[:-1],
                    annotations=catalog.annotations,
                    raw_root=catalog.raw_root,
                ),
                folds=5,
                seed=20260714,
            )

    def test_assignment_requires_four_canonical_date_groups(self):
        catalog = catalog_with_83_mixed_images()
        first = catalog.images[0]
        images = (
            CatalogImage(
                key=first.key,
                absolute_path=first.absolute_path,
                sha256=first.sha256,
                width=first.width,
                height=first.height,
                source_kind=first.source_kind,
                source_group="Test_20990101",
            ),
            *catalog.images[1:],
        )

        with self.assertRaises(SplitError):
            assign_folds(
                Catalog(
                    labels=catalog.labels,
                    images=images,
                    annotations=catalog.annotations,
                    raw_root=catalog.raw_root,
                ),
                folds=5,
                seed=20260714,
            )

    def test_held_out_image_cannot_appear_as_synthetic_source(self):
        with self.assertRaises(LeakageError):
            assert_no_mixed_scene_leakage(
                {"Test_20260714/E0501.jpg": 2},
                [DerivedRecord("x", "Test_20260714/E0501.jpg", 2)],
            )

    def test_unknown_mixed_source_fails_closed(self):
        with self.assertRaises(LeakageError):
            assert_no_mixed_scene_leakage(
                {"Test_20260714/E0501.jpg": 2},
                [DerivedRecord("x", "Test_20260710/E9999.jpg", 1)],
            )

    def test_partially_malformed_provenance_fails_closed(self):
        assignments = {"Test_20260714/E0501.jpg": 2}
        malformed_records = (
            SimpleNamespace(output_key="x", source_key="", fold=1),
            SimpleNamespace(
                output_key="x",
                source_key="Bread01/a.jpg",
                source_keys=("Test_20260714/E0501.jpg", None),
                fold=1,
            ),
            SimpleNamespace(
                output_key="x",
                source_key="Bread01/a.jpg",
                source_keys=("",),
                fold=1,
            ),
            SimpleNamespace(
                output_key="x",
                source_key="Bread01/a.jpg",
                source_keys="Test_20260714/E0501.jpg",
                fold=1,
            ),
            SimpleNamespace(
                output_key="x",
                source_key="Bread01/a.jpg",
                background_key=" ",
                fold=1,
            ),
        )

        for record in malformed_records:
            with self.subTest(record=record), self.assertRaises(LeakageError):
                assert_no_mixed_scene_leakage(assignments, [record])


class CatalogLoadingTest(unittest.TestCase):
    def test_bbox_requires_four_number_json_array(self):
        invalid_boxes = (
            "0123",
            {"0": 0, "1": 0, "2": 1, "3": 1},
            [0, 0, 1],
            [0, 0, True, 1],
            ["0", 0, 1, 1],
        )
        for bbox in invalid_boxes:
            with self.subTest(bbox=bbox), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "catalog.json"
                payload = {
                    "raw_root": "C:/raw",
                    "labels": [{"id": 1, "name": "Walnut Donut"}],
                    "images": [
                        {
                            "key": "Test_20260714/E0501.jpg",
                            "absolute_path": "C:/raw/Test_20260714/E0501.jpg",
                            "sha256": "a" * 64,
                            "width": 100,
                            "height": 80,
                            "source_kind": "mixed_scene",
                            "source_group": "Test_20260714",
                            "category_id": None,
                            "category_name": None,
                        }
                    ],
                    "annotations": [
                        {
                            "annotation_id": "a1",
                            "image_key": "Test_20260714/E0501.jpg",
                            "category_id": 1,
                            "category_name": "Walnut Donut",
                            "bbox": bbox,
                        }
                    ],
                }
                path.write_text(json.dumps(payload), encoding="utf-8")

                with self.assertRaises(SplitError):
                    load_catalog(path)


class OutputGuardTest(unittest.TestCase):
    def test_cli_rejects_lookalike_output_directories_outside_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raw_root = root / "raw"
            raw_root.mkdir()
            catalog = catalog_with_83_mixed_images()
            payload = catalog.to_json()
            payload["raw_root"] = str(raw_root)
            catalog_path = root / "catalog.json"
            catalog_path.write_text(json.dumps(payload), encoding="utf-8")
            audit_output = root / "unrelated" / "outputs" / "audit.json"
            split_output = root / "unrelated" / "datasets" / "split.json"

            with self.assertRaises(SplitError):
                main(
                    [
                        "--catalog",
                        str(catalog_path),
                        "--audit-output",
                        str(audit_output),
                        "--split-output",
                        str(split_output),
                    ]
                )

            self.assertFalse(audit_output.exists())
            self.assertFalse(split_output.exists())

    def test_cli_rejects_outputs_below_catalog_raw_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raw_root = root / "raw"
            raw_root.mkdir()
            catalog = catalog_with_83_mixed_images()
            payload = catalog.to_json()
            payload["raw_root"] = str(raw_root)
            catalog_path = root / "catalog.json"
            catalog_path.write_text(json.dumps(payload), encoding="utf-8")
            audit_output = raw_root / "outputs" / "audit.json"
            split_output = raw_root / "datasets" / "split.json"

            with self.assertRaises(SplitError):
                main(
                    [
                        "--catalog",
                        str(catalog_path),
                        "--audit-output",
                        str(audit_output),
                        "--split-output",
                        str(split_output),
                    ]
                )

            self.assertFalse(audit_output.exists())
            self.assertFalse(split_output.exists())


class SingleProductGroupingTest(unittest.TestCase):
    def setUp(self):
        self.temp_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_directory.name)

    def tearDown(self):
        self.temp_directory.cleanup()

    def _image_record(self, group, name, pixels):
        directory = self.root / group
        directory.mkdir(exist_ok=True)
        path = directory / name
        success, encoded = cv2.imencode(".png", pixels)
        self.assertTrue(success)
        path.write_bytes(encoded.tobytes())
        return CatalogImage(
            key=f"{group}/{name}",
            absolute_path=str(path),
            sha256=name.encode().hex().ljust(64, "0")[:64],
            width=pixels.shape[1],
            height=pixels.shape[0],
            source_kind="single_bread",
            source_group=group,
            category_id=int(group[-2:]),
            category_name=f"Label {int(group[-2:])}",
        )

    def test_near_duplicates_share_one_auxiliary_fold_within_folder(self):
        gradient = np.tile(np.arange(32, dtype=np.uint8), (32, 1))
        pixels = cv2.merge([gradient, gradient, gradient])
        changed = cv2.convertScaleAbs(pixels, alpha=1.1, beta=2)
        records = [
            self._image_record("Bread01", "a.png", pixels),
            self._image_record("Bread01", "b.png", changed),
            self._image_record("Bread02", "c.png", pixels),
        ]
        catalog = Catalog(
            labels=LABELS,
            images=tuple(records),
            annotations=(),
            raw_root=str(self.root),
        )

        groups = group_single_product_images(catalog, max_hamming_distance=4)
        assignments = assign_single_product_folds(catalog, folds=5, seed=20260714)

        self.assertIn(("Bread01/a.png", "Bread01/b.png"), groups)
        self.assertNotIn("Bread02/c.png", next(group for group in groups if "Bread01/a.png" in group))
        self.assertEqual(assignments["Bread01/a.png"], assignments["Bread01/b.png"])


if __name__ == "__main__":
    unittest.main()
