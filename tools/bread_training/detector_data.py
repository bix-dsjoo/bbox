"""Materialize leakage-safe, real-only YOLO detector datasets."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import tempfile
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from pathlib import PureWindowsPath
from typing import Any, Mapping, Sequence


FOLD_COUNT = 5


@dataclass(frozen=True)
class DetectorFoldManifest:
    heldout_fold: int
    validation_fold: int
    dataset_root: Path
    dataset_yaml: Path
    train_keys: tuple[str, ...]
    validation_keys: tuple[str, ...]
    test_keys: tuple[str, ...]


def coco_xywh_to_yolo(
    box: Sequence[float], width: int, height: int
) -> tuple[int, float, float, float, float]:
    """Convert a validated COCO pixel bbox to one-class normalized YOLO values."""

    if len(box) != 4:
        raise ValueError("bbox must contain exactly four values")
    if (
        type(width) is not int
        or type(height) is not int
        or width <= 0
        or height <= 0
    ):
        raise ValueError("image dimensions must be positive integers")
    x, y, box_width, box_height = (float(value) for value in box)
    values = (x, y, box_width, box_height)
    if not all(math.isfinite(value) for value in values):
        raise ValueError("bbox values must be finite")
    if x < 0 or y < 0 or box_width <= 0 or box_height <= 0:
        raise ValueError("bbox must have a non-negative origin and positive dimensions")
    if x + box_width > width or y + box_height > height:
        raise ValueError("bbox is outside image bounds")
    return (
        0,
        (x + box_width / 2.0) / width,
        (y + box_height / 2.0) / height,
        box_width / width,
        box_height / height,
    )


def _catalog_mapping(catalog: Any) -> Mapping[str, Any]:
    if isinstance(catalog, Mapping):
        return catalog
    to_json = getattr(catalog, "to_json", None)
    if callable(to_json):
        value = to_json()
        if isinstance(value, Mapping):
            return value
    raise TypeError("catalog must be a mapping or expose to_json()")


def _safe_output_root(catalog: Mapping[str, Any], output_root: Path) -> Path:
    output = Path(output_root).resolve()
    raw_value = catalog.get("raw_root")
    if isinstance(raw_value, str) and raw_value.strip():
        raw_root = Path(raw_value).resolve()
        try:
            output.relative_to(raw_root)
        except ValueError:
            pass
        else:
            raise ValueError("detector dataset output must not be below the raw root")
    output.parent.mkdir(parents=True, exist_ok=True)
    return output


def _relative_image_path(key: str, source: Path) -> Path:
    if not isinstance(key, str) or not key or key != key.strip():
        raise ValueError("catalog image keys must be non-blank strings")
    key_path = PurePosixPath(key)
    windows_path = PureWindowsPath(key)
    unsafe_parts = any(
        part in ("", ".", "..")
        or part != part.rstrip(" .")
        or ":" in part
        or PureWindowsPath(part).is_reserved()
        for part in key_path.parts
    )
    if (
        "\\" in key
        or key_path.is_absolute()
        or windows_path.is_absolute()
        or bool(windows_path.drive)
        or unsafe_parts
    ):
        raise ValueError(f"unsafe catalog image key: {key}")
    relative = Path(*key_path.parts)
    if relative.suffix.lower() != source.suffix.lower():
        relative = relative.with_suffix(source.suffix.lower())
    return relative


def _source_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _validated_detector_records(catalog: Mapping[str, Any]):
    raw_images = catalog.get("images")
    raw_annotations = catalog.get("annotations")
    if not isinstance(raw_images, list) or not isinstance(raw_annotations, list):
        raise ValueError("catalog images and annotations must be lists")

    images: dict[str, Mapping[str, Any]] = {}
    relative_paths: dict[str, Path] = {}
    for item in raw_images:
        if not isinstance(item, Mapping) or item.get("source_kind") != "mixed_scene":
            continue
        key = item.get("key")
        if not isinstance(key, str) or key in images:
            raise ValueError("mixed image keys must be unique strings")
        source = Path(str(item.get("absolute_path", "")))
        if not source.is_file():
            raise ValueError(f"mixed image source does not exist: {source}")
        width = item.get("width")
        height = item.get("height")
        if (
            type(width) is not int
            or type(height) is not int
            or width <= 0
            or height <= 0
        ):
            raise ValueError(f"invalid image dimensions for {key}")
        sha256 = item.get("sha256")
        if not isinstance(sha256, str) or re.fullmatch(r"[0-9a-fA-F]{64}", sha256) is None:
            raise ValueError(f"invalid image sha256 for {key}")
        actual_sha256 = _source_sha256(source)
        if actual_sha256 != sha256.lower():
            raise ValueError(f"image sha256 does not match source bytes for {key}")
        images[key] = item
        relative_paths[key] = _relative_image_path(key, source)

    if not images:
        raise ValueError("catalog contains no mixed_scene images")
    if len(set(relative_paths.values())) != len(relative_paths):
        raise ValueError("mixed image output paths overlap")
    label_paths = {path.with_suffix(".txt") for path in relative_paths.values()}
    if len(label_paths) != len(relative_paths):
        raise ValueError("mixed image label paths overlap")

    annotations: dict[str, list[Mapping[str, Any]]] = defaultdict(list)
    seen_annotation_ids: set[str] = set()
    for item in raw_annotations:
        if not isinstance(item, Mapping):
            raise ValueError("catalog annotations must be objects")
        annotation_id = item.get("annotation_id")
        image_key = item.get("image_key")
        if not isinstance(annotation_id, str) or not annotation_id:
            raise ValueError("annotation IDs must be non-blank strings")
        if annotation_id in seen_annotation_ids:
            raise ValueError(f"duplicate annotation ID: {annotation_id}")
        if not isinstance(image_key, str) or image_key not in images:
            raise ValueError(f"annotation references unknown mixed image: {image_key}")
        image = images[image_key]
        try:
            coco_xywh_to_yolo(
                item.get("bbox", ()), image["width"], image["height"]
            )
        except (TypeError, ValueError) as error:
            raise ValueError(f"invalid bbox for {annotation_id}: {error}") from error
        annotations[image_key].append(item)
        seen_annotation_ids.add(annotation_id)

    for records in annotations.values():
        records.sort(key=lambda item: str(item["annotation_id"]))
    return images, relative_paths, annotations


def _validated_assignments(
    split: Mapping[str, Any], image_keys: set[str], heldout_fold: int
) -> dict[str, int]:
    if type(heldout_fold) is not int or heldout_fold not in range(FOLD_COUNT):
        raise ValueError("heldout_fold must be an integer from 0 through 4")
    if split.get("folds") != FOLD_COUNT:
        raise ValueError("detector datasets require exactly five folds")
    raw_assignments = split.get("mixed_assignments")
    if not isinstance(raw_assignments, Mapping):
        raise ValueError("split mixed_assignments must be an object")
    assignments: dict[str, int] = {}
    for key, fold in raw_assignments.items():
        if (
            not isinstance(key, str)
            or type(fold) is not int
            or fold not in range(FOLD_COUNT)
        ):
            raise ValueError("mixed assignments require string keys and folds 0 through 4")
        assignments[key] = fold
    if set(assignments) != image_keys:
        raise ValueError("catalog mixed image keys and split assignments must match")
    if set(assignments.values()) != set(range(FOLD_COUNT)):
        raise ValueError("split assignments must cover all five folds")
    return assignments


def _link_or_copy(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.link(source, destination)
    except OSError:
        shutil.copy2(source, destination)


def _safe_dataset_path(dataset_root: Path, *parts: object) -> Path:
    destination = dataset_root.joinpath(*(str(part) for part in parts)).resolve()
    try:
        destination.relative_to(dataset_root.resolve())
    except ValueError as error:
        raise ValueError("detector dataset path escapes staging root") from error
    return destination


def _write_dataset_yaml(
    dataset_root: Path, *, published_root: Path | None = None, all_data: bool = False
) -> Path:
    paths_root = (published_root or dataset_root).resolve()
    train = paths_root / "images" / "train"
    validation = train if all_data else paths_root / "images" / "val"
    test_line = (
        "" if all_data else f"test: {paths_root / 'images' / 'test'}\n"
    )
    dataset_yaml = dataset_root / "dataset.yaml"
    dataset_yaml.write_text(
        f"train: {train}\nval: {validation}\n{test_line}nc: 1\nnames: [bread]\n",
        encoding="utf-8",
    )
    return dataset_yaml


def _materialize_split(
    dataset_root: Path,
    split_name: str,
    keys: Sequence[str],
    images: Mapping[str, Mapping[str, Any]],
    relative_paths: Mapping[str, Path],
    annotations: Mapping[str, Sequence[Mapping[str, Any]]],
    assignments: Mapping[str, int] | None,
) -> list[dict[str, Any]]:
    image_directory = "val" if split_name == "validation" else split_name
    source_records: list[dict[str, Any]] = []
    for key in keys:
        image = images[key]
        source = Path(str(image["absolute_path"]))
        relative = relative_paths[key]
        destination = _safe_dataset_path(
            dataset_root, "images", image_directory, relative
        )
        _link_or_copy(source, destination)
        label_path = _safe_dataset_path(
            dataset_root, "labels", image_directory, relative.with_suffix(".txt")
        )
        label_path.parent.mkdir(parents=True, exist_ok=True)
        lines = []
        annotation_ids = []
        for annotation in annotations.get(key, ()):
            values = coco_xywh_to_yolo(
                annotation["bbox"], int(image["width"]), int(image["height"])
            )
            lines.append(
                " ".join(
                    (str(values[0]), *(f"{value:.8f}" for value in values[1:]))
                )
            )
            annotation_ids.append(str(annotation["annotation_id"]))
        label_path.write_text(
            "\n".join(lines) + ("\n" if lines else ""), encoding="utf-8"
        )
        source_records.append(
            {
                "image_key": key,
                "sha256": str(image["sha256"]),
                "source_fold": assignments[key] if assignments is not None else None,
                "annotation_ids": annotation_ids,
                "output_image": destination.relative_to(dataset_root).as_posix(),
                "output_label": label_path.relative_to(dataset_root).as_posix(),
            }
        )
    return source_records


def _publish(staging: Path, destination: Path, dataset_kind: str) -> None:
    if destination.exists():
        if destination.is_symlink() or not destination.is_dir():
            raise ValueError(
                f"detector dataset destination is not a directory: {destination}"
            )
        manifest_path = destination / "source_manifest.json"
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ValueError(
                f"destination is not a generated detector dataset: {destination}"
            ) from error
        recorded_kind = manifest.get("dataset_kind")
        legacy_matches = (
            dataset_kind == "fold" and type(manifest.get("heldout_fold")) is int
        ) or (dataset_kind == "all_data" and manifest.get("all_data") is True)
        if recorded_kind != dataset_kind and not legacy_matches:
            raise ValueError(
                f"destination is not a generated detector dataset: {destination}"
            )
        shutil.rmtree(destination)
    os.replace(staging, destination)


def build_detector_fold_dataset(
    catalog: Mapping[str, Any],
    split: Mapping[str, Any],
    heldout_fold: int,
    output_root: Path,
) -> DetectorFoldManifest:
    """Build one held-out detector fold with disjoint train/validation/test sets."""

    catalog = _catalog_mapping(catalog)
    images, relative_paths, annotations = _validated_detector_records(catalog)
    assignments = _validated_assignments(split, set(images), heldout_fold)
    validation_fold = (heldout_fold + 1) % FOLD_COUNT
    test_keys = tuple(
        sorted(key for key, fold in assignments.items() if fold == heldout_fold)
    )
    validation_keys = tuple(
        sorted(key for key, fold in assignments.items() if fold == validation_fold)
    )
    train_keys = tuple(
        sorted(
            key
            for key, fold in assignments.items()
            if fold not in (heldout_fold, validation_fold)
        )
    )
    sets = (set(train_keys), set(validation_keys), set(test_keys))
    if any(
        sets[left] & sets[right]
        for left in range(3)
        for right in range(left + 1, 3)
    ):
        raise ValueError("detector source sets overlap")
    hash_sets = tuple({str(images[key]["sha256"]) for key in keys} for keys in sets)
    if any(
        hash_sets[left] & hash_sets[right]
        for left in range(3)
        for right in range(left + 1, 3)
    ):
        raise ValueError("detector source hashes overlap across splits")

    root = _safe_output_root(catalog, Path(output_root))
    root.mkdir(parents=True, exist_ok=True)
    destination = root / f"fold_{heldout_fold}"
    staging = Path(tempfile.mkdtemp(prefix=f".fold_{heldout_fold}-staging-", dir=root))
    try:
        records = {
            name: _materialize_split(
                staging, name, keys, images, relative_paths, annotations, assignments
            )
            for name, keys in (
                ("train", train_keys),
                ("validation", validation_keys),
                ("test", test_keys),
            )
        }
        _write_dataset_yaml(staging, published_root=destination)
        (staging / "source_manifest.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "dataset_kind": "fold",
                    "heldout_fold": heldout_fold,
                    "validation_fold": validation_fold,
                    "splits": records,
                },
                indent=2,
                ensure_ascii=False,
            )
            + "\n",
            encoding="utf-8",
        )
        _publish(staging, destination, "fold")
    except BaseException:
        if staging.exists():
            shutil.rmtree(staging)
        raise

    return DetectorFoldManifest(
        heldout_fold=heldout_fold,
        validation_fold=validation_fold,
        dataset_root=destination,
        dataset_yaml=destination / "dataset.yaml",
        train_keys=train_keys,
        validation_keys=validation_keys,
        test_keys=test_keys,
    )


def build_detector_all_data(catalog: Mapping[str, Any], output_root: Path) -> Path:
    """Build an all-real-data training dataset for a final selected detector."""

    catalog = _catalog_mapping(catalog)
    images, relative_paths, annotations = _validated_detector_records(catalog)
    root = _safe_output_root(catalog, Path(output_root))
    root.mkdir(parents=True, exist_ok=True)
    destination = root / "all_data"
    staging = Path(
        tempfile.mkdtemp(prefix=".all_data-staging-", dir=root)
    )
    try:
        keys = tuple(sorted(images))
        records = _materialize_split(
            staging, "train", keys, images, relative_paths, annotations, None
        )
        _write_dataset_yaml(staging, published_root=destination, all_data=True)
        (staging / "source_manifest.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "dataset_kind": "all_data",
                    "all_data": True,
                    "splits": {"train": records},
                },
                indent=2,
                ensure_ascii=False,
            )
            + "\n",
            encoding="utf-8",
        )
        _publish(staging, destination, "all_data")
    except BaseException:
        if staging.exists():
            shutil.rmtree(staging)
        raise
    return destination


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", required=True, type=Path)
    parser.add_argument("--split", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
    split = json.loads(args.split.read_text(encoding="utf-8"))
    manifests = [
        build_detector_fold_dataset(catalog, split, fold, args.output)
        for fold in range(FOLD_COUNT)
    ]
    test_keys = [key for manifest in manifests for key in manifest.test_keys]
    annotations_by_key: dict[str, int] = defaultdict(int)
    for annotation in catalog["annotations"]:
        annotations_by_key[str(annotation["image_key"])] += 1
    summary = {
        "fold_test_sizes": [len(manifest.test_keys) for manifest in manifests],
        "unique_test_keys": len(set(test_keys)),
        "heldout_annotations": sum(annotations_by_key[key] for key in test_keys),
        "dataset_roots": [str(manifest.dataset_root) for manifest in manifests],
    }
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
