"""Fail-closed structural and geometry audit for bread catalogs."""

from __future__ import annotations

import math
from dataclasses import asdict, dataclass
from typing import Any

from tools.bread_training.catalog import Catalog


@dataclass(frozen=True)
class AuditIssue:
    code: str
    message: str
    image_key: str | None = None
    annotation_id: str | None = None

    def to_json(self) -> dict[str, Any]:
        return {key: value for key, value in asdict(self).items() if value is not None}


@dataclass(frozen=True)
class AuditReport:
    image_count: int
    annotation_count: int
    issues: tuple[AuditIssue, ...]

    @property
    def ok(self) -> bool:
        return not self.issues

    def to_json(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "summary": {
                "images": self.image_count,
                "annotations": self.annotation_count,
                "issues": len(self.issues),
            },
            "issues": [issue.to_json() for issue in self.issues],
        }


def _issue(
    issues: list[AuditIssue],
    code: str,
    message: str,
    *,
    image_key: str | None = None,
    annotation_id: str | None = None,
) -> None:
    issues.append(
        AuditIssue(
            code=code,
            message=message,
            image_key=image_key,
            annotation_id=annotation_id,
        )
    )


def audit_catalog(catalog: Catalog) -> AuditReport:
    """Return every catalog integrity problem without trusting upstream parsing."""

    issues: list[AuditIssue] = []
    label_names: dict[int, str] = {}
    for category_id, category_name in catalog.labels:
        if type(category_id) is not int:
            _issue(
                issues,
                "category_id_invalid",
                "Catalog category id must be an integer",
            )
        elif category_id in label_names:
            _issue(
                issues,
                "duplicate_category_id",
                f"Category id {category_id} appears more than once",
            )
        else:
            label_names[category_id] = category_name

    images_by_key = {}
    for image in catalog.images:
        if image.key in images_by_key:
            _issue(
                issues,
                "duplicate_image_key",
                "Image key appears more than once",
                image_key=image.key,
            )
            continue
        images_by_key[image.key] = image
        dimensions = (image.width, image.height)
        if not all(isinstance(value, (int, float)) and math.isfinite(value) for value in dimensions):
            _issue(
                issues,
                "image_dimensions_non_finite",
                "Image dimensions must be finite numbers",
                image_key=image.key,
            )
        elif image.width <= 0 or image.height <= 0:
            _issue(
                issues,
                "image_dimensions_non_positive",
                "Image dimensions must be positive",
                image_key=image.key,
            )
        if image.source_kind == "single_bread":
            if image.category_id is None or image.category_name is None:
                _issue(
                    issues,
                    "single_image_category_missing",
                    "Single-product image must have a category id and name",
                    image_key=image.key,
                )
            elif (
                type(image.category_id) is not int
                or label_names.get(image.category_id) != image.category_name
            ):
                _issue(
                    issues,
                    "single_image_category_mismatch",
                    "Single-product image category must match the catalog registry",
                    image_key=image.key,
                )
        elif image.source_kind == "mixed_scene" and (
            image.category_id is not None or image.category_name is not None
        ):
            _issue(
                issues,
                "mixed_image_category_present",
                "Mixed-scene image category metadata must be unset",
                image_key=image.key,
            )

    seen_annotation_ids: set[str] = set()
    seen_boxes: set[tuple[str, tuple[float, ...]]] = set()
    duplicate_boxes: set[tuple[str, tuple[float, ...]]] = set()
    for annotation in catalog.annotations:
        if annotation.annotation_id in seen_annotation_ids:
            _issue(
                issues,
                "duplicate_annotation_id",
                "Annotation id appears more than once",
                image_key=annotation.image_key,
                annotation_id=annotation.annotation_id,
            )
        else:
            seen_annotation_ids.add(annotation.annotation_id)

        image = images_by_key.get(annotation.image_key)
        if image is None:
            _issue(
                issues,
                "annotation_image_missing",
                "Annotation references an image key that does not exist",
                image_key=annotation.image_key,
                annotation_id=annotation.annotation_id,
            )

        if type(annotation.category_id) is not int:
            _issue(
                issues,
                "annotation_category_id_invalid",
                "Annotation category id must be an integer",
                image_key=annotation.image_key,
                annotation_id=annotation.annotation_id,
            )
        elif (expected_name := label_names.get(annotation.category_id)) is None:
            _issue(
                issues,
                "category_missing",
                f"Category id {annotation.category_id} is not in the catalog registry",
                image_key=annotation.image_key,
                annotation_id=annotation.annotation_id,
            )
        elif annotation.category_name != expected_name:
            _issue(
                issues,
                "category_name_mismatch",
                "Annotation category name does not match the catalog registry",
                image_key=annotation.image_key,
                annotation_id=annotation.annotation_id,
            )

        bbox = annotation.bbox
        if not isinstance(bbox, (tuple, list)) or len(bbox) != 4:
            _issue(
                issues,
                "bbox_invalid",
                "Bounding box must contain x, y, width, and height",
                image_key=annotation.image_key,
                annotation_id=annotation.annotation_id,
            )
            continue
        try:
            values = tuple(float(value) for value in bbox)
        except (TypeError, ValueError):
            _issue(
                issues,
                "bbox_invalid",
                "Bounding box values must be numeric",
                image_key=annotation.image_key,
                annotation_id=annotation.annotation_id,
            )
            continue

        if not all(math.isfinite(value) for value in values):
            _issue(
                issues,
                "bbox_non_finite",
                "Bounding box values must be finite",
                image_key=annotation.image_key,
                annotation_id=annotation.annotation_id,
            )
            continue

        box_key = (annotation.image_key, values)
        if box_key in seen_boxes and box_key not in duplicate_boxes:
            duplicate_boxes.add(box_key)
            _issue(
                issues,
                "duplicate_bbox",
                "Image contains an exact duplicate bounding box",
                image_key=annotation.image_key,
                annotation_id=annotation.annotation_id,
            )
        else:
            seen_boxes.add(box_key)

        x, y, width, height = values
        if width <= 0 or height <= 0:
            _issue(
                issues,
                "bbox_dimensions_non_positive",
                "Bounding box width and height must be positive",
                image_key=annotation.image_key,
                annotation_id=annotation.annotation_id,
            )
            continue
        image_dimensions_valid = image is not None and all(
            isinstance(value, (int, float)) and math.isfinite(value) and value > 0
            for value in (image.width, image.height)
        )
        if image_dimensions_valid and (
            x < 0
            or y < 0
            or x + width > image.width
            or y + height > image.height
        ):
            _issue(
                issues,
                "bbox_out_of_bounds",
                "Bounding box extends beyond the image bounds",
                image_key=annotation.image_key,
                annotation_id=annotation.annotation_id,
            )

    return AuditReport(
        image_count=len(catalog.images),
        annotation_count=len(catalog.annotations),
        issues=tuple(issues),
    )
