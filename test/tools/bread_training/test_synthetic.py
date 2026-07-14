import hashlib
import json
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path
from unittest import mock

import cv2
import numpy as np

from tools.bread_training.catalog import Catalog, CatalogAnnotation, CatalogImage
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
    visible_halo_score,
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
    cv2.imencode(".png", image)[1].tofile(str(path))


def _write_mask(path: Path) -> str:
    mask = np.zeros((120, 160), dtype=np.uint8)
    cv2.ellipse(mask, (80, 62), (42, 29), 0, 0, 360, 255, -1)
    cv2.imencode(".png", mask)[1].tofile(str(path))
    return hashlib.sha256((mask > 0).astype(np.uint8).tobytes()).hexdigest()


def _audited_fixture(
    raw_root: Path, audit_root: Path, single_count: int = 2
) -> tuple[Catalog, dict[str, object]]:
    singles = []
    single_assignments = {}
    approvals = {}
    for index in range(single_count):
        key = f"Bread01/{index}.png"
        image_path = raw_root / f"bread-{index}.png"
        mask_path = audit_root / f"bread-{index}-mask.png"
        background_path = audit_root / f"bread-{index}-background.png"
        _write_image(image_path, (45 - index, 125 - index, 220 - index))
        mask_sha256 = _write_mask(mask_path)
        source = cv2.imread(str(image_path), cv2.IMREAD_COLOR)
        mask = cv2.imread(str(mask_path), cv2.IMREAD_GRAYSCALE)
        removal_mask = cv2.dilate(
            mask, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13))
        )
        audited_background = cv2.inpaint(source, removal_mask, 7, cv2.INPAINT_TELEA)
        cv2.imencode(".png", audited_background)[1].tofile(str(background_path))
        singles.append(
            CatalogImage(
                key,
                str(image_path),
                hashlib.sha256(image_path.read_bytes()).hexdigest(),
                160,
                120,
                "single_bread",
                "Bread01",
                1,
                "Bread",
            )
        )
        single_assignments[key] = 1 + index % 4
        approvals[key] = {
            "kind": "accepted_foreground_removal",
            "mask_path": str(mask_path),
            "mask_sha256": mask_sha256,
            "background_path": str(background_path),
            "background_sha256": hashlib.sha256(
                background_path.read_bytes()
            ).hexdigest(),
            "foreground_mask_accepted": True,
            "residual_background_accepted": True,
            "audit_id": f"fixture-audit-{index}",
        }
    mixed = (
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
            "a", mixed[0].key, 1, "Bread", (100.0, 100.0, 150.0, 150.0)
        ),
        CatalogAnnotation(
            "b", mixed[1].key, 1, "Bread", (80.0, 100.0, 260.0, 220.0)
        ),
    )
    catalog = Catalog(
        ((1, "Bread"),), (*singles, *mixed), annotations, str(raw_root)
    )
    assignments: dict[str, object] = {
        "mixed_assignments": {mixed[0].key: 0, mixed[1].key: 1},
        "single_product_assignments": single_assignments,
        "approved_backgrounds": approvals,
    }
    return catalog, assignments


def _fold_status(output: Path, fold: int) -> dict[str, object]:
    payload = json.loads((output / "status.json").read_text(encoding="utf-8"))
    return payload["folds"][str(fold)]


def _tree_snapshot(root: Path) -> dict[str, bytes]:
    return {
        path.relative_to(root).as_posix(): path.read_bytes()
        for path in sorted(item for item in root.rglob("*") if item.is_file())
    }


class SyntheticPolicyTest(unittest.TestCase):
    def test_rejects_held_out_mixed_background(self):
        records = [
            BackgroundFixture(
                "Test_20260710/E0501.jpg", "mixed_scene", 3, False
            )
        ]
        with self.assertRaises(LeakageError):
            choose_background(
                records, 3, "Test_20260710/E0501.jpg"
            )

    def test_choose_background_requires_explicit_approval(self):
        records = [BackgroundFixture("Bread01/a.jpg", "single_bread", 1, False)]
        with self.assertRaisesRegex(SyntheticQualityError, "unapproved_background"):
            choose_background(records, 0, "Bread01/a.jpg")

    def test_choose_background_rejects_malformed_fold_provenance(self):
        records = [BackgroundFixture("Bread01/a.jpg", "single_bread", None, True)]
        with self.assertRaisesRegex(
            SyntheticQualityError, "malformed_background_fold"
        ):
            choose_background(records, 0, "Bread01/a.jpg")

    def test_sampler_caps_synthetic_at_half_batch(self):
        kinds = balanced_batch_kinds(7, 50, 8)
        self.assertLessEqual(kinds.count("synthetic"), 4)
        self.assertEqual(len(kinds), 8)

    def test_sampler_never_uses_more_synthetic_than_real_samples(self):
        kinds = balanced_batch_kinds(1, 50, 8)
        self.assertLessEqual(kinds.count("synthetic"), kinds.count("real"))

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
        with self.assertRaisesRegex(SyntheticQualityError, "clipped_foreground"):
            validate_mask_quality(
                mask,
                clipped_coverage=0.979,
                halo_score=0.0,
                object_area_ratio=0.1,
                training_area_range=(0.05, 0.2),
            )

    def test_halo_measurement_distinguishes_clean_edge_from_visible_fringe(self):
        mask = np.zeros((48, 48), np.uint8)
        mask[14:34, 14:34] = 255
        clean = np.full((48, 48, 3), (25, 30, 35), np.uint8)
        clean[mask > 0] = (45, 125, 220)
        fringed = clean.copy()
        fringed[11:37, 11:37] = (45, 125, 220)
        fringed[mask > 0] = (45, 125, 220)

        clean_score = visible_halo_score(clean, mask)
        fringe_score = visible_halo_score(fringed, mask)

        self.assertLess(clean_score, 0.10)
        self.assertGreater(fringe_score, 0.10)

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
            validate_scene_boxes((left, right), 0.25)


class SyntheticBuildTest(unittest.TestCase):
    def setUp(self):
        DATASETS_ROOT.mkdir(parents=True, exist_ok=True)

    def test_catalog_and_split_without_audit_evidence_disable_backgrounds(self):
        with tempfile.TemporaryDirectory() as raw_temp, tempfile.TemporaryDirectory(
            dir=DATASETS_ROOT, prefix="synthetic-audit-"
        ) as audit_temp, tempfile.TemporaryDirectory(
            dir=DATASETS_ROOT, prefix="synthetic-disabled-"
        ) as output_temp:
            catalog, assignments = _audited_fixture(
                Path(raw_temp), Path(audit_temp)
            )
            assignments.pop("approved_backgrounds")
            output = Path(output_temp)

            records = build_synthetic_fold(catalog, assignments, 0, output, 3, 99)

            self.assertEqual(records, [])
            self.assertEqual(
                _fold_status(output, 0)["disabled_reason"],
                "no_approved_backgrounds",
            )
            self.assertEqual(list((output / "images" / "train").glob("*.jpg")), [])
            self.assertEqual(list((output / "labels" / "train").glob("*.txt")), [])
            self.assertEqual((output / "lineage.jsonl").read_text("utf-8"), "")

    def test_incomplete_background_audit_evidence_is_not_approval(self):
        with tempfile.TemporaryDirectory() as raw_temp, tempfile.TemporaryDirectory(
            dir=DATASETS_ROOT, prefix="synthetic-audit-"
        ) as audit_temp, tempfile.TemporaryDirectory(
            dir=DATASETS_ROOT, prefix="synthetic-incomplete-"
        ) as output_temp:
            catalog, assignments = _audited_fixture(Path(raw_temp), Path(audit_temp))
            approvals = assignments["approved_backgrounds"]
            for approval in approvals.values():
                approval["residual_background_accepted"] = False
            output = Path(output_temp)

            records = build_synthetic_fold(catalog, assignments, 0, output, 1, 7)

            self.assertEqual(records, [])
            self.assertEqual(
                _fold_status(output, 0)["disabled_reason"],
                "no_approved_backgrounds",
            )

    def test_build_is_deterministic_and_writes_complete_lineage(self):
        with tempfile.TemporaryDirectory() as raw_temp, tempfile.TemporaryDirectory(
            dir=DATASETS_ROOT, prefix="synthetic-audit-"
        ) as audit_temp, tempfile.TemporaryDirectory(
            dir=DATASETS_ROOT, prefix="synthetic-first-"
        ) as first_temp, tempfile.TemporaryDirectory(
            dir=DATASETS_ROOT, prefix="synthetic-second-"
        ) as second_temp:
            catalog, assignments = _audited_fixture(Path(raw_temp), Path(audit_temp))
            first_output = Path(first_temp)
            second_output = Path(second_temp)

            first = build_synthetic_fold(
                catalog, assignments, 0, first_output, 2, 20260714
            )
            second = build_synthetic_fold(
                catalog, assignments, 0, second_output, 2, 20260714
            )

            self.assertEqual(first, second)
            self.assertEqual(len(first), 2)
            self.assertTrue(all(record.transforms for record in first))
            self.assertTrue(all(len(record.mask_sha256) == 64 for record in first))
            self.assertEqual(
                len(list((first_output / "images" / "train").glob("*.jpg"))), 2
            )
            self.assertEqual(
                len(list((first_output / "labels" / "train").glob("*.txt"))), 2
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
        with tempfile.TemporaryDirectory() as raw_temp, tempfile.TemporaryDirectory(
            dir=DATASETS_ROOT, prefix="synthetic-audit-"
        ) as audit_temp, tempfile.TemporaryDirectory(
            dir=DATASETS_ROOT, prefix="synthetic-bounded-"
        ) as output_temp:
            catalog, assignments = _audited_fixture(
                Path(raw_temp), Path(audit_temp), single_count=6
            )
            output = Path(output_temp)

            records = build_synthetic_fold(
                catalog, assignments, 0, output, 1, 20260714
            )

            self.assertEqual(len(records), 1)
            self.assertLessEqual(_fold_status(output, 0)["approved_backgrounds"], 4)

    def test_rebuilding_one_fold_preserves_other_fold_artifacts(self):
        with tempfile.TemporaryDirectory() as raw_temp, tempfile.TemporaryDirectory(
            dir=DATASETS_ROOT, prefix="synthetic-audit-"
        ) as audit_temp, tempfile.TemporaryDirectory(
            dir=DATASETS_ROOT, prefix="synthetic-shared-"
        ) as output_temp:
            catalog, assignments = _audited_fixture(Path(raw_temp), Path(audit_temp))
            assignments.pop("approved_backgrounds")
            output = Path(output_temp)
            image = output / "images" / "train" / "synth_fold1_00000.jpg"
            label = output / "labels" / "train" / "synth_fold1_00000.txt"
            image.parent.mkdir(parents=True)
            label.parent.mkdir(parents=True)
            image.write_bytes(b"fold-one-image")
            label.write_text("fold-one-label\n", encoding="utf-8")
            fold_one_lineage = {
                "output_key": "images/train/synth_fold1_00000.jpg",
                "fold": 1,
                "seed": 1,
                "background_key": "Bread01/0.png",
                "source_keys": ["Bread01/1.png"],
                "transforms": [{}],
                "mask_sha256": "a" * 64,
                "boxes_xywh": [[1, 1, 2, 2]],
            }
            (output / "lineage.jsonl").write_text(
                json.dumps(fold_one_lineage, sort_keys=True) + "\n", encoding="utf-8"
            )
            fold_one_status = {
                "fold": 1,
                "seed": 1,
                "requested_count": 1,
                "generated_count": 1,
                "approved_backgrounds": 1,
                "disabled_reason": None,
            }
            (output / "status.json").write_text(
                json.dumps({"schema_version": 2, "folds": {"1": fold_one_status}})
                + "\n",
                encoding="utf-8",
            )

            build_synthetic_fold(catalog, assignments, 0, output, 1, 7)

            self.assertEqual(image.read_bytes(), b"fold-one-image")
            self.assertEqual(label.read_text("utf-8"), "fold-one-label\n")
            lines = [
                json.loads(line)
                for line in (output / "lineage.jsonl").read_text("utf-8").splitlines()
            ]
            self.assertEqual(lines, [fold_one_lineage])
            self.assertEqual(_fold_status(output, 1), fold_one_status)
            self.assertEqual(
                _fold_status(output, 0)["disabled_reason"],
                "no_approved_backgrounds",
            )

    def test_injected_failures_leave_previous_output_byte_identical(self):
        with tempfile.TemporaryDirectory() as raw_temp, tempfile.TemporaryDirectory(
            dir=DATASETS_ROOT, prefix="synthetic-audit-"
        ) as audit_temp, tempfile.TemporaryDirectory(
            dir=DATASETS_ROOT, prefix="synthetic-transaction-"
        ) as output_temp:
            catalog, assignments = _audited_fixture(Path(raw_temp), Path(audit_temp))
            output = Path(output_temp)
            build_synthetic_fold(catalog, assignments, 0, output, 1, 17)
            expected = _tree_snapshot(output)
            injections = (
                (
                    "_transformed_object",
                    SyntheticQualityError("injected_quality_failure"),
                ),
                ("_encode_jpeg", OSError("injected_encoding_failure")),
                ("_write_text", OSError("injected_write_failure")),
            )

            for function_name, error in injections:
                with self.subTest(function_name=function_name), mock.patch(
                    f"tools.bread_training.synthetic.{function_name}",
                    side_effect=error,
                ):
                    with self.assertRaises(type(error)):
                        build_synthetic_fold(
                            catalog, assignments, 0, output, 2, 18
                        )
                self.assertEqual(_tree_snapshot(output), expected)


if __name__ == "__main__":
    unittest.main()
