import hashlib
import json
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

from tools.bread_training.catalog import (
    Catalog,
    CatalogAnnotation,
    CatalogImage,
)
from tools.bread_training.split import LeakageError
from tools.bread_training.synthetic import (
    SyntheticQualityError,
    balanced_batch_kinds,
    build_synthetic_fold,
    choose_background,
    mask_bbox,
    overlap_fraction_of_smaller,
    validate_mask_quality,
    validate_scene_boxes,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
DATASETS_ROOT = REPOSITORY_ROOT / "datasets"


@dataclass(frozen=True)
class BackgroundFixture:
    key: str
    source_kind: str
    fold: int
    approved: bool


def _write_image(path: Path, color: tuple[int, int, int]) -> None:
    image = np.full((120, 160, 3), 205, dtype=np.uint8)
    cv2.ellipse(image, (80, 62), (42, 29), 0, 0, 360, color, -1)
    encoded = cv2.imencode(".png", image)[1]
    encoded.tofile(str(path))


class SyntheticPolicyTest(unittest.TestCase):
    def test_rejects_held_out_mixed_background(self):
        records = [
            BackgroundFixture(
                "Test_20260710/E0501.jpg", "mixed_scene", 3, False
            )
        ]

        with self.assertRaises(LeakageError):
            choose_background(
                records,
                held_out_fold=3,
                candidate_key="Test_20260710/E0501.jpg",
            )

    def test_choose_background_requires_explicit_approval(self):
        records = [
            BackgroundFixture("Bread01/a.jpg", "single_bread", 1, False)
        ]

        with self.assertRaisesRegex(
            SyntheticQualityError, "unapproved_background"
        ):
            choose_background(
                records, held_out_fold=0, candidate_key="Bread01/a.jpg"
            )

    def test_choose_background_rejects_malformed_fold_provenance(self):
        records = [
            BackgroundFixture("Bread01/a.jpg", "single_bread", None, True)
        ]

        with self.assertRaisesRegex(
            SyntheticQualityError, "malformed_background_fold"
        ):
            choose_background(
                records, held_out_fold=0, candidate_key="Bread01/a.jpg"
            )

    def test_sampler_caps_synthetic_at_half_batch(self):
        kinds = balanced_batch_kinds(
            real_count=7, synthetic_count=50, batch_size=8
        )

        self.assertLessEqual(kinds.count("synthetic"), 4)
        self.assertEqual(len(kinds), 8)

    def test_sampler_never_uses_more_synthetic_than_real_samples(self):
        kinds = balanced_batch_kinds(
            real_count=1, synthetic_count=50, batch_size=8
        )

        self.assertLessEqual(
            kinds.count("synthetic"), kinds.count("real")
        )

    def test_bbox_is_mask_extent_without_padding(self):
        mask = np.zeros((20, 30), np.uint8)
        mask[4:15, 7:22] = 255

        self.assertEqual(mask_bbox(mask), (7, 4, 15, 11))

    def test_empty_mask_is_rejected(self):
        with self.assertRaisesRegex(SyntheticQualityError, "empty_mask"):
            mask_bbox(np.zeros((8, 8), np.uint8))

    def test_multiple_large_mask_components_are_rejected(self):
        mask = np.zeros((80, 100), np.uint8)
        mask[10:45, 10:45] = 255
        mask[20:52, 60:92] = 255

        with self.assertRaisesRegex(
            SyntheticQualityError, "multiple_large_components"
        ):
            validate_mask_quality(
                mask,
                clipped_coverage=1.0,
                halo_score=0.0,
                object_area_ratio=0.1,
                training_area_range=(0.05, 0.2),
            )

    def test_clipped_foreground_below_98_percent_is_rejected(self):
        mask = np.zeros((40, 50), np.uint8)
        mask[8:32, 10:40] = 255

        with self.assertRaisesRegex(
            SyntheticQualityError, "clipped_foreground"
        ):
            validate_mask_quality(
                mask,
                clipped_coverage=0.979,
                halo_score=0.0,
                object_area_ratio=0.1,
                training_area_range=(0.05, 0.2),
            )

    def test_visible_halo_above_threshold_is_rejected(self):
        mask = np.zeros((40, 50), np.uint8)
        mask[8:32, 10:40] = 255

        with self.assertRaisesRegex(SyntheticQualityError, "visible_halo"):
            validate_mask_quality(
                mask,
                clipped_coverage=1.0,
                halo_score=0.11,
                max_halo_score=0.10,
                object_area_ratio=0.1,
                training_area_range=(0.05, 0.2),
            )

    def test_object_area_outside_training_percentiles_is_rejected(self):
        mask = np.zeros((40, 50), np.uint8)
        mask[8:32, 10:40] = 255

        with self.assertRaisesRegex(
            SyntheticQualityError, "object_area_out_of_range"
        ):
            validate_mask_quality(
                mask,
                clipped_coverage=1.0,
                halo_score=0.0,
                object_area_ratio=0.21,
                training_area_range=(0.05, 0.2),
            )

    def test_overlap_is_measured_against_smaller_object_and_capped(self):
        left = (0, 0, 20, 20)
        right = (10, 0, 10, 20)

        self.assertEqual(overlap_fraction_of_smaller(left, right), 1.0)
        with self.assertRaisesRegex(SyntheticQualityError, "object_overlap"):
            validate_scene_boxes((left, right), max_overlap=0.25)


class SyntheticBuildTest(unittest.TestCase):
    def setUp(self):
        DATASETS_ROOT.mkdir(parents=True, exist_ok=True)

    def test_no_approved_backgrounds_disables_without_substitution(self):
        catalog = Catalog(
            labels=((1, "Bread"),),
            images=(
                CatalogImage(
                    key="Test_20260710/E0501.jpg",
                    absolute_path="unused",
                    sha256="0" * 64,
                    width=640,
                    height=640,
                    source_kind="mixed_scene",
                    source_group="Test_20260710",
                ),
            ),
            annotations=(),
            raw_root=str(REPOSITORY_ROOT / "raw-fixture"),
        )
        assignments = {
            "mixed_assignments": {"Test_20260710/E0501.jpg": 0},
            "single_product_assignments": {},
        }

        with tempfile.TemporaryDirectory(
            dir=DATASETS_ROOT, prefix="synthetic-disabled-"
        ) as temp:
            output = Path(temp)
            records = build_synthetic_fold(
                catalog, assignments, fold=0, output=output, count=3, seed=99
            )
            status = json.loads(
                (output / "status.json").read_text(encoding="utf-8")
            )

            self.assertEqual(records, [])
            self.assertEqual(status["disabled_reason"], "no_approved_backgrounds")
            self.assertEqual(status["generated_count"], 0)
            self.assertEqual(
                (output / "lineage.jsonl").read_text(encoding="utf-8"), ""
            )

    def test_build_is_deterministic_and_writes_complete_lineage(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            raw_root = Path(raw_temp)
            first_path = raw_root / "bread-a.png"
            second_path = raw_root / "bread-b.png"
            _write_image(first_path, (45, 125, 220))
            _write_image(second_path, (35, 105, 190))
            images = (
                CatalogImage(
                    "Bread01/a.png",
                    str(first_path),
                    hashlib.sha256(first_path.read_bytes()).hexdigest(),
                    160,
                    120,
                    "single_bread",
                    "Bread01",
                    1,
                    "Bread",
                ),
                CatalogImage(
                    "Bread01/b.png",
                    str(second_path),
                    hashlib.sha256(second_path.read_bytes()).hexdigest(),
                    160,
                    120,
                    "single_bread",
                    "Bread01",
                    1,
                    "Bread",
                ),
                CatalogImage(
                    "Test_20260710/E0501.jpg",
                    "unused-a",
                    "1" * 64,
                    640,
                    640,
                    "mixed_scene",
                    "Test_20260710",
                ),
                CatalogImage(
                    "Test_20260714/E0502.jpg",
                    "unused-b",
                    "2" * 64,
                    640,
                    640,
                    "mixed_scene",
                    "Test_20260714",
                ),
            )
            annotations = (
                CatalogAnnotation(
                    "a",
                    "Test_20260710/E0501.jpg",
                    1,
                    "Bread",
                    (100.0, 100.0, 150.0, 150.0),
                ),
                CatalogAnnotation(
                    "b",
                    "Test_20260714/E0502.jpg",
                    1,
                    "Bread",
                    (80.0, 100.0, 260.0, 220.0),
                ),
            )
            catalog = Catalog(((1, "Bread"),), images, annotations, str(raw_root))
            assignments = {
                "mixed_assignments": {
                    "Test_20260710/E0501.jpg": 0,
                    "Test_20260714/E0502.jpg": 1,
                },
                "single_product_assignments": {
                    "Bread01/a.png": 1,
                    "Bread01/b.png": 2,
                },
            }

            with tempfile.TemporaryDirectory(
                dir=DATASETS_ROOT, prefix="synthetic-first-"
            ) as first_temp, tempfile.TemporaryDirectory(
                dir=DATASETS_ROOT, prefix="synthetic-second-"
            ) as second_temp:
                first_output = Path(first_temp)
                second_output = Path(second_temp)
                first = build_synthetic_fold(
                    catalog,
                    assignments,
                    fold=0,
                    output=first_output,
                    count=2,
                    seed=20260714,
                )
                second = build_synthetic_fold(
                    catalog,
                    assignments,
                    fold=0,
                    output=second_output,
                    count=2,
                    seed=20260714,
                )

                self.assertEqual(first, second)
                self.assertEqual(len(first), 2)
                self.assertTrue(all(record.transforms for record in first))
                self.assertTrue(
                    all(
                        not key.startswith("Test_")
                        for record in first
                        for key in (record.background_key, *record.source_keys)
                    )
                )
                self.assertTrue(
                    all(len(record.mask_sha256) == 64 for record in first)
                )
                self.assertEqual(
                    len(list((first_output / "images" / "train").glob("*.jpg"))),
                    2,
                )
                self.assertEqual(
                    len(list((first_output / "labels" / "train").glob("*.txt"))),
                    2,
                )
                lineage = [
                    json.loads(line)
                    for line in (first_output / "lineage.jsonl")
                    .read_text(encoding="utf-8")
                    .splitlines()
                ]
                self.assertEqual(len(lineage), 2)
                self.assertEqual(lineage[0]["seed"], first[0].seed)
                self.assertEqual(lineage[0]["source_keys"], list(first[0].source_keys))
                self.assertEqual(lineage[0]["mask_sha256"], first[0].mask_sha256)
                self.assertEqual(
                    lineage[0]["boxes_xywh"],
                    [list(box) for box in first[0].boxes_xywh],
                )
                self.assertEqual(lineage[0]["transforms"], list(first[0].transforms))

    def test_builder_stops_after_bounded_approved_background_pool(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            raw_root = Path(raw_temp)
            image_path = raw_root / "bread.png"
            _write_image(image_path, (45, 125, 220))
            checksum = hashlib.sha256(image_path.read_bytes()).hexdigest()
            singles = tuple(
                CatalogImage(
                    f"Bread01/{index}.png",
                    str(image_path),
                    checksum,
                    160,
                    120,
                    "single_bread",
                    "Bread01",
                    1,
                    "Bread",
                )
                for index in range(6)
            )
            mixed = CatalogImage(
                "Test_20260714/E0502.jpg",
                "unused",
                "2" * 64,
                640,
                640,
                "mixed_scene",
                "Test_20260714",
            )
            catalog = Catalog(
                ((1, "Bread"),),
                (*singles, mixed),
                (
                    CatalogAnnotation(
                        "a",
                        mixed.key,
                        1,
                        "Bread",
                        (80.0, 100.0, 260.0, 220.0),
                    ),
                ),
                str(raw_root),
            )
            assignments = {
                "mixed_assignments": {mixed.key: 1},
                "single_product_assignments": {
                    image.key: 1 for image in singles
                },
            }
            with tempfile.TemporaryDirectory(
                dir=DATASETS_ROOT, prefix="synthetic-bounded-"
            ) as temp:
                output = Path(temp)

                records = build_synthetic_fold(
                    catalog,
                    assignments,
                    fold=0,
                    output=output,
                    count=1,
                    seed=20260714,
                )
                status = json.loads(
                    (output / "status.json").read_text(encoding="utf-8")
                )

                self.assertEqual(len(records), 1)
                self.assertLessEqual(status["approved_backgrounds"], 4)


if __name__ == "__main__":
    unittest.main()
