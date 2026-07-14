"""Build a deterministic, read-only catalog of the canonical bread data."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable

import cv2
import numpy as np


CANONICAL_LABELS: tuple[tuple[int, str], ...] = (
    (1, "Walnut Donut"),
    (2, "Croffle"),
    (3, "Waffle"),
    (4, "Scon"),
    (5, "Half-moon Croissant"),
    (6, "Croissant"),
    (7, "Flower Bread"),
    (8, "Almond Scon"),
    (9, "Dinner Roll"),
    (10, "Sugar Donut"),
    (11, "Bagel"),
    (12, "Egg Tart"),
    (13, "Muffin"),
    (14, "Burger"),
    (15, "Sandwich"),
    (16, "Grain Campagne"),
    (17, "Almond Campagne"),
    (18, "Mini Bread"),
    (19, "Pastry Bread"),
    (20, "Plain Bread"),
)

MIXED_DIRECTORY_NAMES = (
    "Test_20260706",
    "Test_20260708",
    "Test_20260710",
    "Test_20260714",
)

SUPPORTED_IMAGE_SUFFIXES = frozenset(
    {".bmp", ".jpeg", ".jpg", ".png", ".tif", ".tiff", ".webp"}
)


@dataclass(frozen=True)
class CatalogImage:
    key: str
    absolute_path: str
    sha256: str
    width: int
    height: int
    source_kind: str
    source_group: str
    category_id: int | None = None
    category_name: str | None = None


@dataclass(frozen=True)
class CatalogAnnotation:
    annotation_id: str
    image_key: str
    category_id: int
    category_name: str
    bbox: tuple[float, float, float, float]


@dataclass(frozen=True)
class Catalog:
    labels: tuple[tuple[int, str], ...]
    images: tuple[CatalogImage, ...]
    annotations: tuple[CatalogAnnotation, ...]
    raw_root: str

    def to_json(self) -> dict[str, Any]:
        return {
            "raw_root": self.raw_root,
            "labels": [
                {"id": category_id, "name": name}
                for category_id, name in self.labels
            ],
            "images": [asdict(image) for image in self.images],
            "annotations": [
                {
                    **asdict(annotation),
                    "bbox": list(annotation.bbox),
                }
                for annotation in self.annotations
            ],
        }


def normalize_category_name(value: str) -> str:
    return " ".join(value.strip().split())


def mixed_coco_path(raw_root: Path, directory: Path) -> Path:
    del raw_root
    return directory / f"{directory.name}.json"


def canonical_image_key(raw_root: Path, path: Path) -> str:
    return path.relative_to(raw_root).as_posix()


def _require_json_integer(value: Any, field_name: str) -> int:
    if type(value) is not int:
        raise ValueError(f"{field_name} must be a JSON integer")
    return value


def _read_labels_registry(raw_root: Path) -> tuple[tuple[int, str], ...]:
    labels_path = raw_root / "labels.txt"
    if not labels_path.is_file():
        raise ValueError(f"Missing labels.txt registry: {labels_path}")

    labels: list[tuple[int, str]] = []
    for line_number, raw_line in enumerate(
        labels_path.read_text(encoding="utf-8-sig").splitlines(), start=1
    ):
        line = raw_line.strip()
        if not line:
            continue
        match = re.fullmatch(r"(\d+)\.\s*(.+)", line)
        if match is None:
            raise ValueError(f"Invalid labels.txt entry at line {line_number}: {raw_line!r}")
        labels.append((int(match.group(1)), normalize_category_name(match.group(2))))

    registry = tuple(labels)
    if registry != CANONICAL_LABELS:
        raise ValueError(
            "labels.txt does not match the canonical ordered category registry"
        )
    return registry


def _supported_image_paths(directory: Path) -> list[Path]:
    return sorted(
        (
            path
            for path in directory.iterdir()
            if path.is_file() and path.suffix.lower() in SUPPORTED_IMAGE_SUFFIXES
        ),
        key=lambda path: path.name.casefold(),
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _decoded_dimensions(path: Path) -> tuple[int, int]:
    encoded = np.fromfile(path, dtype=np.uint8)
    image = cv2.imdecode(encoded, cv2.IMREAD_COLOR)
    if image is None:
        raise ValueError(f"Could not decode image: {path}")
    height, width = image.shape[:2]
    return int(width), int(height)


def _catalog_image(
    raw_root: Path,
    path: Path,
    *,
    source_kind: str,
    source_group: str,
    category_id: int | None = None,
    category_name: str | None = None,
) -> CatalogImage:
    width, height = _decoded_dimensions(path)
    return CatalogImage(
        key=canonical_image_key(raw_root, path),
        absolute_path=str(path.resolve()),
        sha256=_sha256(path),
        width=width,
        height=height,
        source_kind=source_kind,
        source_group=source_group,
        category_id=category_id,
        category_name=category_name,
    )


def _validate_bread_directories(raw_root: Path) -> None:
    for path in raw_root.iterdir():
        if not path.is_dir():
            continue
        match = re.fullmatch(r"Bread(\d+)", path.name)
        if match is not None and int(match.group(1)) not in range(1, 21):
            raise ValueError(f"Bread directory suffix is outside 1-20: {path.name}")


def _require_directory(raw_root: Path, name: str) -> Path:
    directory = raw_root / name
    if not directory.is_dir():
        raise ValueError(f"Missing required directory: {name}")
    return directory


def _normalized_categories(payload: dict[str, Any]) -> tuple[tuple[int, str], ...]:
    categories = payload.get("categories")
    if not isinstance(categories, list):
        raise ValueError("COCO category registry must be a list")

    normalized: list[tuple[int, str]] = []
    for category in categories:
        try:
            raw_category_id = category["id"]
            category_name = normalize_category_name(str(category["name"]))
        except (KeyError, TypeError) as error:
            raise ValueError("Invalid COCO category registry") from error
        normalized.append(
            (_require_json_integer(raw_category_id, "COCO category id"), category_name)
        )
    registry = tuple(sorted(normalized))

    if registry != CANONICAL_LABELS:
        raise ValueError("COCO category registry does not match the canonical registry")
    return registry


def _safe_mixed_image_path(directory: Path, file_name: str) -> Path:
    path = (directory / Path(file_name)).resolve()
    try:
        path.relative_to(directory.resolve())
    except ValueError as error:
        raise ValueError(f"COCO image path escapes its source directory: {file_name}") from error
    if not path.is_file():
        raise ValueError(f"Missing COCO image file: {path}")
    return path


def _mixed_records(
    raw_root: Path, directory: Path
) -> tuple[list[CatalogImage], list[CatalogAnnotation]]:
    coco_path = mixed_coco_path(raw_root, directory)
    if not coco_path.is_file():
        raise ValueError(f"Missing matching COCO file: {coco_path}")
    try:
        payload = json.loads(coco_path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"Could not parse COCO file: {coco_path}") from error
    if not isinstance(payload, dict):
        raise ValueError(f"COCO root must be an object: {coco_path}")

    _normalized_categories(payload)
    raw_images = payload.get("images")
    raw_annotations = payload.get("annotations")
    if not isinstance(raw_images, list) or not isinstance(raw_annotations, list):
        raise ValueError(f"COCO images and annotations must be lists: {coco_path}")

    images: list[CatalogImage] = []
    image_keys_by_id: dict[int, str] = {}
    declared_names: set[str] = set()
    for raw_image in raw_images:
        try:
            raw_image_id = raw_image["id"]
            file_name = str(raw_image["file_name"])
        except (KeyError, TypeError) as error:
            raise ValueError(f"Invalid COCO image record in {coco_path}") from error
        image_id = _require_json_integer(raw_image_id, "COCO image id")
        if image_id in image_keys_by_id:
            raise ValueError(f"Duplicate COCO image id in {coco_path}: {image_id}")

        image_path = _safe_mixed_image_path(directory, file_name)
        image = _catalog_image(
            raw_root,
            image_path,
            source_kind="mixed_scene",
            source_group=directory.name,
        )
        declared_width = raw_image.get("width")
        declared_height = raw_image.get("height")
        if (declared_width, declared_height) != (image.width, image.height):
            raise ValueError(
                f"COCO dimensions do not match decoded image {image.key}: "
                f"declared={declared_width}x{declared_height}, "
                f"decoded={image.width}x{image.height}"
            )
        images.append(image)
        image_keys_by_id[image_id] = image.key
        declared_names.add(image_path.name.casefold())

    actual_names = {path.name.casefold() for path in _supported_image_paths(directory)}
    if actual_names != declared_names:
        raise ValueError(
            f"COCO image registry does not match files in {directory.name}: "
            f"declared={len(declared_names)}, files={len(actual_names)}"
        )

    annotations: list[CatalogAnnotation] = []
    seen_annotation_ids: set[str] = set()
    canonical_names = dict(CANONICAL_LABELS)
    for raw_annotation in raw_annotations:
        try:
            raw_annotation_id = raw_annotation["id"]
            raw_image_id = raw_annotation["image_id"]
            raw_category_id = raw_annotation["category_id"]
            raw_bbox = raw_annotation["bbox"]
            if not isinstance(raw_bbox, list) or len(raw_bbox) != 4:
                raise ValueError("bbox must contain four values")
            bbox = tuple(float(value) for value in raw_bbox)
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError(f"Invalid COCO annotation in {coco_path}") from error

        annotation_id_value = _require_json_integer(
            raw_annotation_id, "COCO annotation id"
        )
        image_id = _require_json_integer(raw_image_id, "COCO annotation image_id")
        category_id = _require_json_integer(
            raw_category_id, "COCO annotation category_id"
        )
        annotation_id = f"{directory.name}:{annotation_id_value}"

        if annotation_id in seen_annotation_ids:
            raise ValueError(f"Duplicate COCO annotation id: {annotation_id}")
        if image_id not in image_keys_by_id:
            raise ValueError(f"Unknown COCO image id in {coco_path}: {image_id}")
        if category_id not in canonical_names:
            raise ValueError(f"Category id is outside the canonical registry: {category_id}")

        annotations.append(
            CatalogAnnotation(
                annotation_id=annotation_id,
                image_key=image_keys_by_id[image_id],
                category_id=category_id,
                category_name=canonical_names[category_id],
                bbox=bbox,
            )
        )
        seen_annotation_ids.add(annotation_id)

    return images, annotations


def build_catalog(raw_root: Path) -> Catalog:
    raw_root = raw_root.resolve()
    if not raw_root.is_dir():
        raise ValueError(f"Raw root is not a directory: {raw_root}")

    labels = _read_labels_registry(raw_root)
    _validate_bread_directories(raw_root)

    images: list[CatalogImage] = []
    annotations: list[CatalogAnnotation] = []
    canonical_names = dict(labels)
    for category_id in range(1, 21):
        directory = _require_directory(raw_root, f"Bread{category_id:02d}")
        images.extend(
            _catalog_image(
                raw_root,
                image_path,
                source_kind="single_bread",
                source_group=directory.name,
                category_id=category_id,
                category_name=canonical_names[category_id],
            )
            for image_path in _supported_image_paths(directory)
        )

    for directory_name in MIXED_DIRECTORY_NAMES:
        directory = _require_directory(raw_root, directory_name)
        mixed_images, mixed_annotations = _mixed_records(raw_root, directory)
        images.extend(mixed_images)
        annotations.extend(mixed_annotations)

    return Catalog(
        labels=labels,
        images=tuple(sorted(images, key=lambda image: image.key.casefold())),
        annotations=tuple(annotations),
        raw_root=str(raw_root),
    )


def write_catalog(catalog: Catalog, path: Path) -> None:
    output_path = path.resolve()
    raw_root = Path(catalog.raw_root).resolve()
    try:
        output_path.relative_to(raw_root)
    except ValueError:
        pass
    else:
        raise ValueError(f"Refusing to write catalog under raw root: {output_path}")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(catalog.to_json(), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def _count_source(catalog: Catalog, source_kind: str) -> int:
    return sum(image.source_kind == source_kind for image in catalog.images)


def _parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    args = _parse_args(argv)
    catalog = build_catalog(args.raw_root)
    write_catalog(catalog, args.output)
    print(
        f"single_images={_count_source(catalog, 'single_bread')} "
        f"mixed_images={_count_source(catalog, 'mixed_scene')} "
        f"annotations={len(catalog.annotations)} "
        f"output={args.output.resolve()}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
