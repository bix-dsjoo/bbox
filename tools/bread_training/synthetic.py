"""Build deterministic, leakage-safe synthetic bread detector samples."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
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


def _warm_mask(image: np.ndarray) -> np.ndarray:
    hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)
    hue, saturation, value = cv2.split(hsv)
    blue, green, red = cv2.split(image)
    maximum = np.maximum.reduce([blue, green, red])
    minimum = np.minimum.reduce([blue, green, red])
    chroma = maximum - minimum
    warm_hue = ((hue <= 42) | (hue >= 168)) & (saturation >= 18) & (value >= 45)
    warm_rgb = (
        (red.astype(np.int16) > green.astype(np.int16) - 8)
        & (red.astype(np.int16) > blue.astype(np.int16) + 12)
        & (value >= 55)
        & (chroma >= 14)
    )
    mask = (warm_hue | warm_rgb).astype(np.uint8) * 255
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
    return cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=2)


def _halo_score(image: np.ndarray, mask: np.ndarray) -> float:
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
    ring = (cv2.dilate(mask, kernel) > 0) & (mask == 0)
    if not np.any(ring):
        return 0.0
    warm = _warm_mask(image) > 0
    return float(np.count_nonzero(warm & ring) / np.count_nonzero(ring))


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


def _approved_asset(
    image: CatalogImage, assigned_fold: int, size: int
) -> _ApprovedAsset:
    decoded = _decode_image(image)
    mask = _warm_mask(decoded)
    halo = _halo_score(decoded, mask)
    bbox = validate_mask_quality(
        mask,
        clipped_coverage=_foreground_coverage(mask),
        halo_score=halo,
    )
    removal_mask = cv2.dilate(
        mask, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13))
    )
    background = cv2.inpaint(decoded, removal_mask, 7, cv2.INPAINT_TELEA)
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
) -> tuple[dict[str, int], dict[str, int]]:
    if not isinstance(assignments, Mapping):
        raise LeakageError("Fold assignments must be a mapping")
    if "mixed_assignments" in assignments or "single_product_assignments" in assignments:
        mixed_value = assignments.get("mixed_assignments", {})
        single_value = assignments.get("single_product_assignments", {})
        if not isinstance(mixed_value, Mapping) or not isinstance(single_value, Mapping):
            raise LeakageError("Split assignment sections must be mappings")
        mixed = dict(mixed_value)
        single = dict(single_value)
    else:
        mixed = {key: value for key, value in assignments.items() if str(key).startswith("Test_")}
        single = {
            key: value for key, value in assignments.items() if not str(key).startswith("Test_")
        }
    for group in (mixed, single):
        for key, value in group.items():
            if not isinstance(key, str) or not key.strip() or type(value) is not int:
                raise LeakageError("Fold assignments require non-blank keys and integer folds")
    return dict(mixed), dict(single)


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


def _prepare_output(output: Path) -> tuple[Path, Path]:
    image_dir = output / "images" / "train"
    label_dir = output / "labels" / "train"
    image_dir.mkdir(parents=True, exist_ok=True)
    label_dir.mkdir(parents=True, exist_ok=True)
    for path in image_dir.glob("synth_fold*_*.jpg"):
        path.unlink()
    for path in label_dir.glob("synth_fold*_*.txt"):
        path.unlink()
    (output / "lineage.jsonl").write_text("", encoding="utf-8")
    return image_dir, label_dir


def _write_status(
    output: Path,
    *,
    fold: int,
    seed: int,
    requested_count: int,
    generated_count: int,
    approved_backgrounds: int,
    disabled_reason: str | None,
) -> None:
    payload = {
        "schema_version": 1,
        "fold": fold,
        "seed": seed,
        "requested_count": requested_count,
        "generated_count": generated_count,
        "approved_backgrounds": approved_backgrounds,
        "disabled_reason": disabled_reason,
    }
    (output / "status.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


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
    path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


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
    mixed_assignments, single_assignments = _assignment_maps(assignments)
    output = _validate_output(Path(output), Path(catalog.raw_root))
    image_dir, label_dir = _prepare_output(output)

    assets: list[_ApprovedAsset] = []
    approved_asset_limit = min(64, max(4, count * 2))
    for image in sorted(catalog.images, key=lambda item: item.key):
        if image.source_kind != "single_bread":
            continue
        assigned_fold = single_assignments.get(image.key)
        if type(assigned_fold) is not int or assigned_fold == fold:
            continue
        try:
            asset = _approved_asset(image, assigned_fold, DEFAULT_SIZE)
            choose_background((asset.candidate,), fold, image.key)
        except SyntheticQualityError:
            continue
        assets.append(asset)
        if len(assets) >= approved_asset_limit:
            break

    if count == 0:
        _write_status(
            output,
            fold=fold,
            seed=seed,
            requested_count=count,
            generated_count=0,
            approved_backgrounds=len(assets),
            disabled_reason=None,
        )
        return []
    if not assets:
        _write_status(
            output,
            fold=fold,
            seed=seed,
            requested_count=count,
            generated_count=0,
            approved_backgrounds=0,
            disabled_reason="no_approved_backgrounds",
        )
        return []

    area_range = _training_area_range(catalog, mixed_assignments, fold)
    records: list[SyntheticRecord] = []
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
            combined_mask = np.zeros((DEFAULT_SIZE, DEFAULT_SIZE), dtype=np.uint8)
            offset_x = int(transform["offset_x"])
            offset_y = int(transform["offset_y"])
            mask_height, mask_width = foreground_mask.shape
            combined_mask[
                offset_y : offset_y + mask_height,
                offset_x : offset_x + mask_width,
            ] = foreground_mask
            stem = f"synth_fold{fold}_{index:05d}"
            output_key = f"images/train/{stem}.jpg"
            image_path = image_dir / f"{stem}.jpg"
            encoded = cv2.imencode(
                ".jpg", canvas, [int(cv2.IMWRITE_JPEG_QUALITY), 92]
            )[1]
            encoded.tofile(str(image_path))
            _write_yolo_label(label_dir / f"{stem}.txt", (box,), DEFAULT_SIZE)
            record = SyntheticRecord(
                output_key=output_key,
                fold=fold,
                seed=scene_seed,
                background_key=background_asset.candidate.key,
                source_keys=(foreground_asset.candidate.key,),
                mask_sha256=hashlib.sha256(combined_mask.tobytes()).hexdigest(),
                boxes_xywh=(box,),
                transforms=(transform,),
            )
            records.append(record)
            break
        else:
            raise SyntheticQualityError(
                f"could_not_build_scene:{index}:{last_error or 'quality_rejected'}"
            )

    assert_no_mixed_scene_leakage(mixed_assignments, records)
    (output / "lineage.jsonl").write_text(
        "".join(
            json.dumps(record.to_json(), ensure_ascii=False, sort_keys=True) + "\n"
            for record in records
        ),
        encoding="utf-8",
    )
    _write_status(
        output,
        fold=fold,
        seed=seed,
        requested_count=count,
        generated_count=len(records),
        approved_backgrounds=len(assets),
        disabled_reason=None,
    )
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
    status = json.loads((args.output / "status.json").read_text(encoding="utf-8"))
    print(
        f"generated_count={len(records)} "
        f"disabled_reason={status['disabled_reason']} output={args.output.resolve()}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
