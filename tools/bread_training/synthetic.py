"""Build deterministic, leakage-safe synthetic bread detector samples."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import shutil
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

import cv2
import numpy as np

from tools.bread_training.catalog import Catalog, CatalogImage
from tools.bread_training.split import (
    LeakageError,
    assert_no_mixed_scene_leakage,
    load_catalog,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SIZE = 640
MIN_FOREGROUND_COVERAGE = 0.98
MAX_HALO_SCORE = 0.10
MAX_COMPONENT_RATIO = 0.10
MAX_OBJECT_OVERLAP = 0.25


class SyntheticQualityError(ValueError):
    """A proposed synthetic asset or scene failed a quality policy."""


@dataclass(frozen=True)
class BackgroundCandidate:
    key: str
    source_kind: str
    fold: int
    approved: bool


@dataclass(frozen=True)
class SyntheticRecord:
    output_key: str
    fold: int
    seed: int
    background_key: str
    source_keys: tuple[str, ...]
    mask_sha256: str
    boxes_xywh: tuple[tuple[int, int, int, int], ...]
    transforms: tuple[dict[str, Any], ...] = ()

    def to_json(self) -> dict[str, Any]:
        return {
            "output_key": self.output_key,
            "fold": self.fold,
            "seed": self.seed,
            "background_key": self.background_key,
            "source_keys": list(self.source_keys),
            "transforms": [dict(transform) for transform in self.transforms],
            "mask_sha256": self.mask_sha256,
            "boxes_xywh": [list(box) for box in self.boxes_xywh],
        }


@dataclass(frozen=True)
class _ApprovedAsset:
    candidate: BackgroundCandidate
    image: np.ndarray
    mask: np.ndarray
    bbox: tuple[int, int, int, int]
    halo_score: float
    background: np.ndarray


def _record_value(record: object, name: str, default: object = None) -> object:
    if isinstance(record, Mapping):
        return record.get(name, default)
    return getattr(record, name, default)


def choose_background(
    records: Iterable[object], held_out_fold: int, candidate_key: str
) -> object:
    """Return an explicitly approved training background or fail closed."""

    if type(held_out_fold) is not int or held_out_fold < 0:
        raise ValueError("held_out_fold must be a non-negative integer")
    candidate = next(
        (
            record
            for record in records
            if _record_value(record, "key", _record_value(record, "background_key"))
            == candidate_key
        ),
        None,
    )
    if candidate is None:
        raise SyntheticQualityError("unknown_background")
    candidate_fold = _record_value(candidate, "fold")
    if type(candidate_fold) is not int or candidate_fold < 0:
        raise SyntheticQualityError("malformed_background_fold")
    source_kind = _record_value(candidate, "source_kind")
    is_mixed = source_kind == "mixed_scene" or candidate_key.startswith("Test_")
    if candidate_fold == held_out_fold:
        raise LeakageError(
            f"Held-out source {candidate_key} cannot be used as a background"
        )
    if is_mixed:
        raise SyntheticQualityError("mixed_scene_background_not_approved")
    if source_kind not in {"single_bread", "audited_tray_background"}:
        raise SyntheticQualityError("unapproved_background_kind")
    if _record_value(candidate, "approved") is not True:
        raise SyntheticQualityError("unapproved_background")
    return candidate


def balanced_batch_kinds(
    real_count: int, synthetic_count: int, batch_size: int
) -> list[str]:
    """Select available samples while capping synthetic samples at half."""

    if any(type(value) is not int for value in (real_count, synthetic_count, batch_size)):
        raise ValueError("sample counts and batch_size must be integers")
    if real_count < 0 or synthetic_count < 0 or batch_size <= 0:
        raise ValueError("sample counts must be non-negative and batch_size positive")
    synthetic_slots = min(synthetic_count, batch_size // 2, real_count)
    real_slots = min(real_count, batch_size - synthetic_slots)
    return ["real"] * real_slots + ["synthetic"] * synthetic_slots


def mask_bbox(mask: np.ndarray) -> tuple[int, int, int, int]:
    """Return the exact inclusive mask extent as integer x/y/width/height."""

    if not isinstance(mask, np.ndarray) or mask.ndim != 2:
        raise SyntheticQualityError("invalid_mask")
    ys, xs = np.where(mask > 0)
    if len(xs) == 0:
        raise SyntheticQualityError("empty_mask")
    return (
        int(xs.min()),
        int(ys.min()),
        int(xs.max() - xs.min() + 1),
        int(ys.max() - ys.min() + 1),
    )


def _large_component_count(mask: np.ndarray) -> int:
    binary = (mask > 0).astype(np.uint8)
    count, _, stats, _ = cv2.connectedComponentsWithStats(binary, connectivity=8)
    areas = sorted((int(area) for area in stats[1:, cv2.CC_STAT_AREA]), reverse=True)
    if not areas:
        return 0
    threshold = max(16, math.ceil(areas[0] * MAX_COMPONENT_RATIO))
    return sum(area >= threshold for area in areas)


def validate_mask_quality(
    mask: np.ndarray,
    *,
    clipped_coverage: float,
    halo_score: float,
    object_area_ratio: float | None = None,
    training_area_range: tuple[float, float] | None = None,
    max_halo_score: float = MAX_HALO_SCORE,
) -> tuple[int, int, int, int]:
    """Validate every mask-level synthetic quality gate."""

    bbox = mask_bbox(mask)
    if _large_component_count(mask) > 1:
        raise SyntheticQualityError("multiple_large_components")
    if not math.isfinite(clipped_coverage) or clipped_coverage < MIN_FOREGROUND_COVERAGE:
        raise SyntheticQualityError("clipped_foreground")
    if not math.isfinite(halo_score) or halo_score > max_halo_score:
        raise SyntheticQualityError("visible_halo")
    if (object_area_ratio is None) != (training_area_range is None):
        raise ValueError("object_area_ratio and training_area_range must be paired")
    if object_area_ratio is not None and training_area_range is not None:
        low, high = training_area_range
        if (
            not all(math.isfinite(value) for value in (object_area_ratio, low, high))
            or low <= 0
            or high < low
            or not low <= object_area_ratio <= high
        ):
            raise SyntheticQualityError("object_area_out_of_range")
    return bbox


def overlap_fraction_of_smaller(
    left: Sequence[float], right: Sequence[float]
) -> float:
    if len(left) != 4 or len(right) != 4:
        raise SyntheticQualityError("invalid_bbox")
    lx, ly, lw, lh = (float(value) for value in left)
    rx, ry, rw, rh = (float(value) for value in right)
    if not all(math.isfinite(value) for value in (lx, ly, lw, lh, rx, ry, rw, rh)):
        raise SyntheticQualityError("invalid_bbox")
    if min(lw, lh, rw, rh) <= 0:
        raise SyntheticQualityError("invalid_bbox")
    intersection_width = max(0.0, min(lx + lw, rx + rw) - max(lx, rx))
    intersection_height = max(0.0, min(ly + lh, ry + rh) - max(ly, ry))
    return (intersection_width * intersection_height) / min(lw * lh, rw * rh)


def validate_scene_boxes(
    boxes: Sequence[Sequence[float]], max_overlap: float = MAX_OBJECT_OVERLAP
) -> None:
    if not math.isfinite(max_overlap) or not 0 <= max_overlap <= 1:
        raise ValueError("max_overlap must be between zero and one")
    for index, left in enumerate(boxes):
        for right in boxes[index + 1 :]:
            if overlap_fraction_of_smaller(left, right) > max_overlap:
                raise SyntheticQualityError("object_overlap")


def visible_halo_score(image: np.ndarray, mask: np.ndarray) -> float:
    """Measure exterior pixels that resemble the foreground more than background."""

    if (
        not isinstance(image, np.ndarray)
        or image.ndim != 3
        or image.shape[2] != 3
        or not isinstance(mask, np.ndarray)
        or mask.ndim != 2
        or image.shape[:2] != mask.shape
    ):
        raise SyntheticQualityError("invalid_halo_fixture")
    binary = (mask > 0).astype(np.uint8)
    mask_bbox(binary)
    inner_kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    outer_kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
    reference_kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (15, 15))
    inner_ring = (binary > 0) & (cv2.erode(binary, inner_kernel) == 0)
    outer_extent = cv2.dilate(binary, outer_kernel) > 0
    outer_ring = outer_extent & (binary == 0)
    reference_ring = (cv2.dilate(binary, reference_kernel) > 0) & ~outer_extent
    if not np.any(inner_ring) or not np.any(outer_ring) or not np.any(reference_ring):
        raise SyntheticQualityError("halo_context_missing")
    foreground_color = np.median(image[inner_ring].astype(np.float32), axis=0)
    background_color = np.median(image[reference_ring].astype(np.float32), axis=0)
    exterior = image[outer_ring].astype(np.float32)
    foreground_distance = np.linalg.norm(exterior - foreground_color, axis=1)
    background_distance = np.linalg.norm(exterior - background_color, axis=1)
    return float(np.mean(foreground_distance < background_distance))


def _foreground_coverage(mask: np.ndarray) -> float:
    touches_edge = (
        np.any(mask[0] > 0)
        or np.any(mask[-1] > 0)
        or np.any(mask[:, 0] > 0)
        or np.any(mask[:, -1] > 0)
    )
    return 0.0 if touches_edge else 1.0


def _decode_image(image: CatalogImage) -> np.ndarray:
    try:
        encoded = np.fromfile(image.absolute_path, dtype=np.uint8)
    except OSError as error:
        raise SyntheticQualityError(f"image_read_failed:{image.key}") from error
    decoded = cv2.imdecode(encoded, cv2.IMREAD_COLOR)
    if decoded is None:
        raise SyntheticQualityError(f"image_decode_failed:{image.key}")
    return decoded


def _canonical_mask_sha256(mask: np.ndarray) -> str:
    return hashlib.sha256((mask > 0).astype(np.uint8).tobytes()).hexdigest()


def _validated_audit_path(value: object, raw_root: Path, field: str) -> Path:
    if not isinstance(value, str) or not value.strip() or value != value.strip():
        raise SyntheticQualityError(f"malformed_{field}")
    path = Path(value).resolve()
    try:
        path.relative_to(raw_root.resolve())
    except ValueError:
        pass
    else:
        raise SyntheticQualityError(f"{field}_under_raw_root")
    if not any(
        _is_relative_to(path, (REPOSITORY_ROOT / directory).resolve())
        for directory in ("datasets", "outputs")
    ):
        raise SyntheticQualityError(f"{field}_outside_derived_roots")
    if not path.is_file():
        raise SyntheticQualityError(f"missing_{field}")
    return path


def _is_relative_to(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def _approved_asset(
    image: CatalogImage,
    assigned_fold: int,
    size: int,
    evidence: object,
    raw_root: Path,
) -> _ApprovedAsset:
    if not isinstance(evidence, Mapping):
        raise SyntheticQualityError("missing_background_audit")
    if (
        evidence.get("kind") != "accepted_foreground_removal"
        or evidence.get("foreground_mask_accepted") is not True
        or evidence.get("residual_background_accepted") is not True
        or not isinstance(evidence.get("audit_id"), str)
        or not str(evidence["audit_id"]).strip()
    ):
        raise SyntheticQualityError("incomplete_background_audit")
    decoded = _decode_image(image)
    mask_path = _validated_audit_path(evidence.get("mask_path"), raw_root, "mask_path")
    mask = cv2.imdecode(np.fromfile(mask_path, dtype=np.uint8), cv2.IMREAD_GRAYSCALE)
    if mask is None or mask.shape != decoded.shape[:2]:
        raise SyntheticQualityError("audited_mask_shape_mismatch")
    expected_mask_checksum = evidence.get("mask_sha256")
    if (
        not isinstance(expected_mask_checksum, str)
        or _canonical_mask_sha256(mask) != expected_mask_checksum
    ):
        raise SyntheticQualityError("audited_mask_checksum_mismatch")
    halo = visible_halo_score(decoded, mask)
    bbox = validate_mask_quality(
        mask,
        clipped_coverage=_foreground_coverage(mask),
        halo_score=halo,
    )
    background_path = _validated_audit_path(
        evidence.get("background_path"), raw_root, "background_path"
    )
    expected_background_checksum = evidence.get("background_sha256")
    if (
        not isinstance(expected_background_checksum, str)
        or hashlib.sha256(background_path.read_bytes()).hexdigest()
        != expected_background_checksum
    ):
        raise SyntheticQualityError("audited_background_checksum_mismatch")
    background = cv2.imdecode(
        np.fromfile(background_path, dtype=np.uint8), cv2.IMREAD_COLOR
    )
    if background is None or background.shape != decoded.shape:
        raise SyntheticQualityError("audited_background_shape_mismatch")
    background = cv2.resize(background, (size, size), interpolation=cv2.INTER_AREA)
    return _ApprovedAsset(
        BackgroundCandidate(image.key, image.source_kind, assigned_fold, True),
        decoded,
        mask,
        bbox,
        halo,
        background,
    )


def _assignment_maps(
    assignments: Mapping[str, Any],
) -> tuple[dict[str, int], dict[str, int], dict[str, object]]:
    if not isinstance(assignments, Mapping):
        raise LeakageError("Fold assignments must be a mapping")
    if "mixed_assignments" in assignments or "single_product_assignments" in assignments:
        mixed_value = assignments.get("mixed_assignments", {})
        single_value = assignments.get("single_product_assignments", {})
        approval_value = assignments.get("approved_backgrounds", {})
        if (
            not isinstance(mixed_value, Mapping)
            or not isinstance(single_value, Mapping)
            or not isinstance(approval_value, Mapping)
        ):
            raise LeakageError("Split assignment sections must be mappings")
        mixed = dict(mixed_value)
        single = dict(single_value)
        approvals = dict(approval_value)
    else:
        mixed = {key: value for key, value in assignments.items() if str(key).startswith("Test_")}
        single = {
            key: value for key, value in assignments.items() if not str(key).startswith("Test_")
        }
        approvals = {}
    for group in (mixed, single):
        for key, value in group.items():
            if not isinstance(key, str) or not key.strip() or type(value) is not int:
                raise LeakageError("Fold assignments require non-blank keys and integer folds")
    if any(not isinstance(key, str) or not key.strip() for key in approvals):
        raise LeakageError("Approved background keys must be non-blank strings")
    return dict(mixed), dict(single), approvals


def _training_area_range(
    catalog: Catalog, mixed_assignments: Mapping[str, int], held_out_fold: int
) -> tuple[float, float]:
    images = {image.key: image for image in catalog.images}
    ratios: list[float] = []
    for annotation in catalog.annotations:
        assigned_fold = mixed_assignments.get(annotation.image_key)
        if assigned_fold is None or assigned_fold == held_out_fold:
            continue
        image = images.get(annotation.image_key)
        if image is None or image.width <= 0 or image.height <= 0:
            continue
        _, _, width, height = annotation.bbox
        ratio = float(width * height) / float(image.width * image.height)
        if math.isfinite(ratio) and ratio > 0:
            ratios.append(ratio)
    if not ratios:
        raise SyntheticQualityError("no_real_training_box_areas")
    low, high = np.percentile(np.asarray(ratios, dtype=np.float64), [1, 99])
    return float(low), float(high)


def _validate_output(output: Path, raw_root: Path) -> Path:
    resolved = output.resolve()
    resolved_raw = raw_root.resolve()
    try:
        resolved.relative_to(resolved_raw)
    except ValueError:
        pass
    else:
        raise LeakageError(f"Refusing to write under catalog raw root: {resolved}")
    allowed = False
    for directory in ("datasets", "outputs"):
        try:
            resolved.relative_to((REPOSITORY_ROOT / directory).resolve())
        except ValueError:
            continue
        allowed = True
        break
    if not allowed:
        raise LeakageError(
            f"Synthetic output must be under repository datasets/ or outputs/: {resolved}"
        )
    return resolved


def _write_text(path: Path, value: str) -> None:
    path.write_text(value, encoding="utf-8")


def _encode_jpeg(image: np.ndarray) -> bytes:
    ok, encoded = cv2.imencode(
        ".jpg", image, [int(cv2.IMWRITE_JPEG_QUALITY), 92]
    )
    if not ok:
        raise OSError("jpeg_encoding_failed")
    return encoded.tobytes()


def _create_staging_copy(output: Path, fold: int) -> Path:
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(
        tempfile.mkdtemp(
            prefix=f".{output.name}.fold-{fold}-staging-", dir=output.parent
        )
    )
    if output.exists():
        shutil.copytree(output, staging, dirs_exist_ok=True)
    return staging


def _read_lineage(output: Path) -> list[dict[str, Any]]:
    path = output / "lineage.jsonl"
    if not path.is_file():
        return []
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise SyntheticQualityError(
                f"malformed_existing_lineage:{line_number}"
            ) from error
        if not isinstance(row, dict) or type(row.get("fold")) is not int:
            raise SyntheticQualityError(f"malformed_existing_lineage:{line_number}")
        rows.append(row)
    return rows


def _read_status_folds(output: Path) -> dict[str, dict[str, Any]]:
    path = output / "status.json"
    if not path.is_file():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise SyntheticQualityError("malformed_existing_status") from error
    if not isinstance(payload, dict):
        raise SyntheticQualityError("malformed_existing_status")
    if payload.get("schema_version") == 2 and isinstance(payload.get("folds"), dict):
        result = payload["folds"]
    elif payload.get("schema_version") == 1 and type(payload.get("fold")) is int:
        result = {str(payload["fold"]): payload}
    else:
        raise SyntheticQualityError("malformed_existing_status")
    if any(not isinstance(key, str) or not isinstance(value, dict) for key, value in result.items()):
        raise SyntheticQualityError("malformed_existing_status")
    return {key: dict(value) for key, value in result.items()}


def _prepare_fold_staging(
    staging: Path, fold: int
) -> tuple[Path, Path, list[dict[str, Any]], dict[str, dict[str, Any]]]:
    image_dir = staging / "images" / "train"
    label_dir = staging / "labels" / "train"
    image_dir.mkdir(parents=True, exist_ok=True)
    label_dir.mkdir(parents=True, exist_ok=True)
    for path in image_dir.glob(f"synth_fold{fold}_*.jpg"):
        path.unlink()
    for path in label_dir.glob(f"synth_fold{fold}_*.txt"):
        path.unlink()
    retained_lineage = [row for row in _read_lineage(staging) if row["fold"] != fold]
    statuses = _read_status_folds(staging)
    statuses.pop(str(fold), None)
    return image_dir, label_dir, retained_lineage, statuses


def _write_fold_metadata(
    staging: Path,
    *,
    fold: int,
    seed: int,
    requested_count: int,
    generated_count: int,
    approved_backgrounds: int,
    disabled_reason: str | None,
    retained_lineage: Sequence[Mapping[str, Any]],
    records: Sequence[SyntheticRecord],
    statuses: Mapping[str, Mapping[str, Any]],
) -> None:
    fold_status = {
        "fold": fold,
        "seed": seed,
        "requested_count": requested_count,
        "generated_count": generated_count,
        "approved_backgrounds": approved_backgrounds,
        "disabled_reason": disabled_reason,
    }
    combined_lineage = [dict(row) for row in retained_lineage]
    combined_lineage.extend(record.to_json() for record in records)
    combined_lineage.sort(key=lambda row: (row["fold"], row["output_key"]))
    _write_text(
        staging / "lineage.jsonl",
        "".join(
            json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n"
            for row in combined_lineage
        ),
    )
    combined_statuses = {key: dict(value) for key, value in statuses.items()}
    combined_statuses[str(fold)] = fold_status
    _write_text(
        staging / "status.json",
        json.dumps(
            {"schema_version": 2, "folds": dict(sorted(combined_statuses.items()))},
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        )
        + "\n",
    )


def _validate_staged_fold(staging: Path, fold: int, generated_count: int) -> None:
    image_count = len(list((staging / "images" / "train").glob(f"synth_fold{fold}_*.jpg")))
    label_count = len(list((staging / "labels" / "train").glob(f"synth_fold{fold}_*.txt")))
    lineage_count = sum(row["fold"] == fold for row in _read_lineage(staging))
    status = _read_status_folds(staging).get(str(fold))
    if (
        image_count != generated_count
        or label_count != generated_count
        or lineage_count != generated_count
        or status is None
        or status.get("generated_count") != generated_count
    ):
        raise SyntheticQualityError("staged_fold_validation_failed")


def _publish_staging(staging: Path, output: Path) -> None:
    backup = output.parent / f".{output.name}.backup-{uuid.uuid4().hex}"
    had_output = output.exists()
    if had_output:
        os.replace(output, backup)
    try:
        os.replace(staging, output)
    except BaseException:
        if had_output and backup.exists() and not output.exists():
            os.replace(backup, output)
        raise
    if backup.exists():
        shutil.rmtree(backup, ignore_errors=True)


def _scene_seed(seed: int, fold: int, index: int) -> int:
    digest = hashlib.sha256(f"{seed}:{fold}:{index}".encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big")


def _transformed_object(
    asset: _ApprovedAsset,
    rng: random.Random,
    size: int,
    area_range: tuple[float, float],
) -> tuple[np.ndarray, np.ndarray, tuple[int, int, int, int], dict[str, Any]]:
    x, y, width, height = asset.bbox
    crop = asset.image[y : y + height, x : x + width]
    crop_mask = asset.mask[y : y + height, x : x + width]
    low, high = area_range
    target_ratio = rng.uniform(low, high)
    minimum_pixels = math.ceil(low * size * size - 1e-9)
    maximum_pixels = math.floor(high * size * size + 1e-9)
    target_pixels = target_ratio * size * size
    source_aspect = width / height
    candidates: list[tuple[float, float, int, int]] = []
    for candidate_width in range(1, size + 1):
        minimum_height = max(1, math.ceil(minimum_pixels / candidate_width))
        maximum_height = min(size, maximum_pixels // candidate_width)
        if minimum_height > maximum_height:
            continue
        preferred_height = int(round(target_pixels / candidate_width))
        for candidate_height in {
            minimum_height,
            maximum_height,
            min(maximum_height, max(minimum_height, preferred_height)),
        }:
            candidates.append(
                (
                    abs(math.log((candidate_width / candidate_height) / source_aspect)),
                    abs(candidate_width * candidate_height - target_pixels),
                    candidate_width,
                    candidate_height,
                )
            )
    if not candidates:
        raise SyntheticQualityError("transformed_foreground_out_of_bounds")
    _, _, new_width, new_height = min(candidates)
    transformed = cv2.resize(crop, (new_width, new_height), interpolation=cv2.INTER_AREA)
    transformed_mask = cv2.resize(
        crop_mask, (new_width, new_height), interpolation=cv2.INTER_NEAREST
    )
    flipped = rng.random() < 0.5
    if flipped:
        transformed = cv2.flip(transformed, 1)
        transformed_mask = cv2.flip(transformed_mask, 1)
    offset_x = rng.randint(0, size - new_width)
    offset_y = rng.randint(0, size - new_height)
    local_x, local_y, box_width, box_height = mask_bbox(transformed_mask)
    box = (
        offset_x + local_x,
        offset_y + local_y,
        box_width,
        box_height,
    )
    full_mask = np.zeros((size, size), dtype=np.uint8)
    full_mask[
        offset_y : offset_y + new_height, offset_x : offset_x + new_width
    ] = transformed_mask
    area_ratio = float(box_width * box_height) / float(size * size)
    validate_mask_quality(
        full_mask,
        clipped_coverage=1.0,
        halo_score=asset.halo_score,
        object_area_ratio=area_ratio,
        training_area_range=area_range,
    )
    transform = {
        "source_key": asset.candidate.key,
        "scale_x": new_width / width,
        "scale_y": new_height / height,
        "flip_horizontal": flipped,
        "offset_x": offset_x,
        "offset_y": offset_y,
        "source_mask_bbox_xywh": [x, y, width, height],
        "output_mask_bbox_xywh": list(box),
    }
    return transformed, transformed_mask, box, transform


def _composite(
    canvas: np.ndarray,
    foreground: np.ndarray,
    mask: np.ndarray,
    transform: Mapping[str, Any],
) -> None:
    offset_x = int(transform["offset_x"])
    offset_y = int(transform["offset_y"])
    height, width = mask.shape
    roi = canvas[offset_y : offset_y + height, offset_x : offset_x + width]
    alpha = cv2.GaussianBlur(mask, (3, 3), 0).astype(np.float32) / 255.0
    roi[:] = (
        alpha[:, :, None] * foreground
        + (1.0 - alpha[:, :, None]) * roi.astype(np.float32)
    ).astype(np.uint8)


def _write_yolo_label(
    path: Path, boxes: Sequence[Sequence[int]], size: int
) -> None:
    lines = []
    for x, y, width, height in boxes:
        center_x = (x + width / 2) / size
        center_y = (y + height / 2) / size
        lines.append(
            f"0 {center_x:.8f} {center_y:.8f} {width / size:.8f} {height / size:.8f}"
        )
    _write_text(path, "\n".join(lines) + ("\n" if lines else ""))


def build_synthetic_fold(
    catalog: Catalog,
    assignments: Mapping[str, Any],
    fold: int,
    output: Path,
    count: int,
    seed: int,
) -> list[SyntheticRecord]:
    """Build one training-only synthetic fold and its deterministic lineage."""

    if type(fold) is not int or fold < 0:
        raise ValueError("fold must be a non-negative integer")
    if type(count) is not int or count < 0:
        raise ValueError("count must be a non-negative integer")
    if type(seed) is not int:
        raise ValueError("seed must be an integer")
    mixed_assignments, single_assignments, approvals = _assignment_maps(assignments)
    output = _validate_output(Path(output), Path(catalog.raw_root))
    staging = _create_staging_copy(output, fold)
    try:
        image_dir, label_dir, retained_lineage, statuses = _prepare_fold_staging(
            staging, fold
        )
        assets: list[_ApprovedAsset] = []
        if count > 0:
            approved_asset_limit = min(64, max(4, count * 2))
            for image in sorted(catalog.images, key=lambda item: item.key):
                if image.source_kind != "single_bread":
                    continue
                assigned_fold = single_assignments.get(image.key)
                evidence = approvals.get(image.key)
                if (
                    type(assigned_fold) is not int
                    or assigned_fold == fold
                    or evidence is None
                ):
                    continue
                try:
                    asset = _approved_asset(
                        image,
                        assigned_fold,
                        DEFAULT_SIZE,
                        evidence,
                        Path(catalog.raw_root),
                    )
                    choose_background((asset.candidate,), fold, image.key)
                except SyntheticQualityError:
                    continue
                assets.append(asset)
                if len(assets) >= approved_asset_limit:
                    break

        records: list[SyntheticRecord] = []
        disabled_reason = None
        if count > 0 and not assets:
            disabled_reason = "no_approved_backgrounds"
        elif count > 0:
            area_range = _training_area_range(catalog, mixed_assignments, fold)
            for index in range(count):
                scene_seed = _scene_seed(seed, fold, index)
                rng = random.Random(scene_seed)
                background_asset = rng.choice(assets)
                choose_background(
                    (asset.candidate for asset in assets),
                    held_out_fold=fold,
                    candidate_key=background_asset.candidate.key,
                )
                canvas = background_asset.background.copy()
                last_error: SyntheticQualityError | None = None
                for _ in range(40):
                    foreground_asset = rng.choice(assets)
                    try:
                        foreground, foreground_mask, box, transform = _transformed_object(
                            foreground_asset, rng, DEFAULT_SIZE, area_range
                        )
                        validate_scene_boxes((box,), max_overlap=MAX_OBJECT_OVERLAP)
                    except SyntheticQualityError as error:
                        last_error = error
                        continue
                    _composite(canvas, foreground, foreground_mask, transform)
                    combined_mask = np.zeros(
                        (DEFAULT_SIZE, DEFAULT_SIZE), dtype=np.uint8
                    )
                    offset_x = int(transform["offset_x"])
                    offset_y = int(transform["offset_y"])
                    mask_height, mask_width = foreground_mask.shape
                    combined_mask[
                        offset_y : offset_y + mask_height,
                        offset_x : offset_x + mask_width,
                    ] = foreground_mask
                    stem = f"synth_fold{fold}_{index:05d}"
                    output_key = f"images/train/{stem}.jpg"
                    (image_dir / f"{stem}.jpg").write_bytes(_encode_jpeg(canvas))
                    _write_yolo_label(
                        label_dir / f"{stem}.txt", (box,), DEFAULT_SIZE
                    )
                    records.append(
                        SyntheticRecord(
                            output_key=output_key,
                            fold=fold,
                            seed=scene_seed,
                            background_key=background_asset.candidate.key,
                            source_keys=(foreground_asset.candidate.key,),
                            mask_sha256=hashlib.sha256(
                                combined_mask.tobytes()
                            ).hexdigest(),
                            boxes_xywh=(box,),
                            transforms=(transform,),
                        )
                    )
                    break
                else:
                    raise SyntheticQualityError(
                        f"could_not_build_scene:{index}:"
                        f"{last_error or 'quality_rejected'}"
                    )

        assert_no_mixed_scene_leakage(mixed_assignments, records)
        _write_fold_metadata(
            staging,
            fold=fold,
            seed=seed,
            requested_count=count,
            generated_count=len(records),
            approved_backgrounds=len(assets),
            disabled_reason=disabled_reason,
            retained_lineage=retained_lineage,
            records=records,
            statuses=statuses,
        )
        _validate_staged_fold(staging, fold, len(records))
        _publish_staging(staging, output)
    except BaseException:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
        raise
    return records


def _load_assignments(path: Path) -> Mapping[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise LeakageError(f"Could not read split JSON: {path}") from error
    if not isinstance(payload, Mapping):
        raise LeakageError("Split JSON must contain an object")
    return payload


def _parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", required=True, type=Path)
    parser.add_argument("--split", required=True, type=Path)
    parser.add_argument("--fold", required=True, type=int)
    parser.add_argument("--count", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--seed", type=int, default=20260714)
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    args = _parse_args(argv)
    catalog = load_catalog(args.catalog)
    assignments = _load_assignments(args.split)
    records = build_synthetic_fold(
        catalog,
        assignments,
        fold=args.fold,
        output=args.output,
        count=args.count,
        seed=args.seed,
    )
    status_payload = json.loads(
        (args.output / "status.json").read_text(encoding="utf-8")
    )
    status = status_payload["folds"][str(args.fold)]
    print(
        f"generated_count={len(records)} "
        f"disabled_reason={status['disabled_reason']} output={args.output.resolve()}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
