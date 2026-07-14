import math
import unittest

from tools.bread_training.audit import audit_catalog
from tools.bread_training.catalog import (
    Catalog,
    CatalogAnnotation,
    CatalogImage,
)


LABELS = ((1, "Walnut Donut"), (2, "Croffle"))


def image(
    key="Test_20260714/E0501.jpg",
    width=100,
    height=80,
    source_kind="mixed_scene",
    category_id=None,
    category_name=None,
):
    return CatalogImage(
        key=key,
        absolute_path=f"C:/raw/{key}",
        sha256="a" * 64,
        width=width,
        height=height,
        source_kind=source_kind,
        source_group=key.split("/")[0],
        category_id=category_id,
        category_name=category_name,
    )


def annotation(
    annotation_id="a1",
    image_key="Test_20260714/E0501.jpg",
    category_id=1,
    category_name="Walnut Donut",
    bbox=(10.0, 10.0, 30.0, 20.0),
):
    return CatalogAnnotation(
        annotation_id=annotation_id,
        image_key=image_key,
        category_id=category_id,
        category_name=category_name,
        bbox=bbox,
    )


def catalog(images, annotations):
    return Catalog(
        labels=LABELS,
        images=tuple(images),
        annotations=tuple(annotations),
        raw_root="C:/raw",
    )


class AuditCatalogTest(unittest.TestCase):
    def test_audit_rejects_non_integer_single_image_category_id(self):
        for invalid_id in (True, 1.0):
            with self.subTest(invalid_id=invalid_id):
                record = image(
                    key="Bread01/invalid-id.jpg",
                    source_kind="single_bread",
                    category_id=invalid_id,
                    category_name="Walnut Donut",
                )

                report = audit_catalog(catalog([record], []))

                self.assertEqual(
                    {issue.code for issue in report.issues},
                    {"single_image_category_mismatch"},
                )

    def test_audit_enforces_image_category_metadata_by_source_kind(self):
        report = audit_catalog(
            catalog(
                [
                    image(
                        key="Bread01/valid.jpg",
                        source_kind="single_bread",
                        category_id=1,
                        category_name="Walnut Donut",
                    ),
                    image(key="Bread01/missing.jpg", source_kind="single_bread"),
                    image(
                        key="Bread01/mismatch.jpg",
                        source_kind="single_bread",
                        category_id=1,
                        category_name="Croffle",
                    ),
                    image(
                        key="Bread01/unknown.jpg",
                        source_kind="single_bread",
                        category_id=99,
                        category_name="Unknown",
                    ),
                    image(
                        category_id=1,
                        category_name="Walnut Donut",
                    ),
                ],
                [],
            )
        )

        self.assertEqual(
            {issue.code for issue in report.issues},
            {
                "single_image_category_missing",
                "single_image_category_mismatch",
                "mixed_image_category_present",
            },
        )

    def test_audit_flags_out_of_bounds_and_exact_duplicates(self):
        duplicate = annotation(annotation_id="a2", bbox=(90.0, 70.0, 20.0, 20.0))
        report = audit_catalog(
            catalog(
                [image()],
                [
                    annotation(annotation_id="a1", bbox=duplicate.bbox),
                    duplicate,
                ],
            )
        )

        self.assertEqual(
            {issue.code for issue in report.issues},
            {"bbox_out_of_bounds", "duplicate_bbox"},
        )
        self.assertFalse(report.ok)

    def test_audit_rejects_non_positive_non_finite_and_unresolved_records(self):
        report = audit_catalog(
            catalog(
                [image(width=0)],
                [
                    annotation(annotation_id="finite", bbox=(0.0, 0.0, math.inf, 1.0)),
                    annotation(
                        annotation_id="category",
                        category_id=99,
                        category_name="Unknown",
                    ),
                    annotation(annotation_id="reference", image_key="missing.jpg"),
                ],
            )
        )

        self.assertEqual(
            {issue.code for issue in report.issues},
            {
                "image_dimensions_non_positive",
                "bbox_non_finite",
                "category_missing",
                "annotation_image_missing",
            },
        )

    def test_audit_rejects_non_positive_bbox_dimensions(self):
        report = audit_catalog(
            catalog(
                [image()],
                [
                    annotation(annotation_id="zero", bbox=(1.0, 2.0, 0.0, 4.0)),
                    annotation(annotation_id="negative", bbox=(1.0, 2.0, 3.0, -4.0)),
                ],
            )
        )

        self.assertEqual(
            {issue.code for issue in report.issues}, {"bbox_dimensions_non_positive"}
        )

    def test_audit_rejects_duplicate_record_identifiers(self):
        report = audit_catalog(
            catalog(
                [image(), image()],
                [annotation(), annotation(bbox=(20.0, 20.0, 10.0, 10.0))],
            )
        )

        self.assertEqual(
            {issue.code for issue in report.issues},
            {"duplicate_image_key", "duplicate_annotation_id"},
        )

    def test_clean_report_serializes_counts(self):
        report = audit_catalog(catalog([image()], [annotation()]))

        self.assertTrue(report.ok)
        self.assertEqual(
            report.to_json(),
            {
                "ok": True,
                "summary": {"images": 1, "annotations": 1, "issues": 0},
                "issues": [],
            },
        )


if __name__ == "__main__":
    unittest.main()
