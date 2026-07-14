"""Render detector OOF predictions as a deterministic contact sheet and CSV."""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

from tools.bread_training.metrics import BBox, match_detections


@dataclass(frozen=True)
class OofPrediction:
    bbox: BBox
    confidence: float


@dataclass(frozen=True)
class OofImage:
    fold: int
    image_key: str
    ground_truth: tuple[BBox, ...]
    predictions: tuple[OofPrediction, ...]
    misses: int
    false_positives: int
    latency_ms: float

    @property
    def mean_matched_iou(self) -> float:
        result = match_detections(
            self.ground_truth,
            tuple({"bbox": prediction.bbox} for prediction in self.predictions),
        )
        return statistics.fmean(result.matched_ious) if result.matched_ious else 0.0


def _read_object(path: Path, description: str) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"could not read {description}: {path}") from error
    if not isinstance(payload, dict):
        raise ValueError(f"{description} must be a JSON object")
    return payload


def _bbox(value: Any) -> BBox:
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes)):
        raise ValueError("OOF bbox must be a four-value sequence")
    if len(value) != 4:
        raise ValueError("OOF bbox must contain four values")
    result = tuple(float(item) for item in value)
    if not all(math.isfinite(item) for item in result) or result[2] <= 0 or result[3] <= 0:
        raise ValueError("OOF bbox must be finite with positive size")
    return result  # type: ignore[return-value]


def _oof_image(fold: int, value: Mapping[str, Any]) -> OofImage:
    image_key = value.get("image_key")
    if not isinstance(image_key, str) or not image_key:
        raise ValueError("OOF image_key must be a non-empty string")
    raw_ground_truth = value.get("ground_truth")
    raw_predictions = value.get("operational_predictions")
    if not isinstance(raw_ground_truth, list) or not isinstance(raw_predictions, list):
        raise ValueError("OOF image boxes must be lists")
    predictions = []
    for item in raw_predictions:
        if not isinstance(item, dict) or type(item.get("confidence")) not in (int, float):
            raise ValueError("OOF prediction is malformed")
        confidence = float(item["confidence"])
        if not math.isfinite(confidence) or not 0.0 <= confidence <= 1.0:
            raise ValueError("OOF prediction confidence is invalid")
        predictions.append(OofPrediction(_bbox(item.get("bbox")), confidence))
    return OofImage(
        fold=fold,
        image_key=image_key,
        ground_truth=tuple(_bbox(item) for item in raw_ground_truth),
        predictions=tuple(predictions),
        misses=int(value.get("misses", 0)),
        false_positives=int(value.get("false_positives", 0)),
        latency_ms=float(value.get("latency_ms", 0.0)),
    )


def collect_source_images(
    selection_path: Path, *, source_prefix: str
) -> tuple[OofImage, ...]:
    selection = _read_object(selection_path, "fast detector selection")
    full_oof = selection.get("fullOof")
    if not isinstance(full_oof, dict) or not isinstance(full_oof.get("artifacts"), list):
        raise ValueError("fast detector selection is missing OOF artifacts")
    records = full_oof["artifacts"]
    if len(records) != 5:
        raise ValueError("fast detector selection must contain five OOF artifacts")
    images: dict[str, OofImage] = {}
    observed_folds = set()
    for record in records:
        if not isinstance(record, dict) or type(record.get("fold")) is not int:
            raise ValueError("OOF artifact record is malformed")
        fold = int(record["fold"])
        if fold not in range(5) or fold in observed_folds:
            raise ValueError("OOF artifact folds must be exactly 0 through 4")
        observed_folds.add(fold)
        artifact = _read_object(Path(str(record.get("path", ""))), "OOF artifact")
        if artifact.get("fold") != fold or artifact.get("model_sha256") != record.get(
            "modelSha256"
        ):
            raise ValueError("OOF artifact provenance does not match selection")
        raw_images = artifact.get("images")
        if not isinstance(raw_images, list):
            raise ValueError("OOF artifact images must be a list")
        for raw_image in raw_images:
            if not isinstance(raw_image, dict):
                raise ValueError("OOF image record must be an object")
            image = _oof_image(fold, raw_image)
            if not image.image_key.startswith(source_prefix):
                continue
            if image.image_key in images:
                raise ValueError(f"duplicate OOF image: {image.image_key}")
            images[image.image_key] = image
    if observed_folds != set(range(5)):
        raise ValueError("OOF artifact folds must be exactly 0 through 4")
    return tuple(images[key] for key in sorted(images))


def _draw_dashed_rectangle(draw, coordinates, *, fill, width=3, dash=10):
    left, top, right, bottom = coordinates
    for start in range(int(left), int(right), dash * 2):
        draw.line((start, top, min(start + dash, right), top), fill=fill, width=width)
        draw.line((start, bottom, min(start + dash, right), bottom), fill=fill, width=width)
    for start in range(int(top), int(bottom), dash * 2):
        draw.line((left, start, left, min(start + dash, bottom)), fill=fill, width=width)
        draw.line((right, start, right, min(start + dash, bottom)), fill=fill, width=width)


def render_contact_sheet(
    images: Sequence[OofImage],
    *,
    image_root: Path,
    output_path: Path,
    columns: int,
) -> None:
    from PIL import Image, ImageDraw, ImageFont, ImageOps

    if columns <= 0:
        raise ValueError("columns must be positive")
    tile_width, title_height, body_height = 360, 42, 360
    rows = math.ceil(len(images) / columns)
    sheet = Image.new(
        "RGB", (tile_width * columns, (title_height + body_height) * rows), "black"
    )
    font = ImageFont.load_default()
    for index, record in enumerate(images):
        source = image_root / Path(record.image_key)
        with Image.open(source) as opened:
            original = ImageOps.exif_transpose(opened).convert("RGB")
        original_width, original_height = original.size
        scale = min(tile_width / original_width, body_height / original_height)
        resized = original.resize(
            (round(original_width * scale), round(original_height * scale)),
            Image.Resampling.LANCZOS,
        )
        tile = Image.new("RGB", (tile_width, title_height + body_height), "black")
        offset_x = (tile_width - resized.width) // 2
        offset_y = title_height + (body_height - resized.height) // 2
        tile.paste(resized, (offset_x, offset_y))
        draw = ImageDraw.Draw(tile)
        title = (
            f"{Path(record.image_key).name} f{record.fold} "
            f"pred {len(record.predictions)}/GT {len(record.ground_truth)} "
            f"miss {record.misses} IoU {record.mean_matched_iou:.3f}"
        )
        draw.text((6, 6), title, fill="#ff4fd8", font=font)
        for x, y, width, height in record.ground_truth:
            _draw_dashed_rectangle(
                draw,
                (
                    offset_x + x * scale,
                    offset_y + y * scale,
                    offset_x + (x + width) * scale,
                    offset_y + (y + height) * scale,
                ),
                fill="#ffd400",
            )
        for prediction in record.predictions:
            x, y, width, height = prediction.bbox
            coordinates = (
                offset_x + x * scale,
                offset_y + y * scale,
                offset_x + (x + width) * scale,
                offset_y + (y + height) * scale,
            )
            draw.rectangle(coordinates, outline="#ff4fd8", width=3)
            draw.text(
                (coordinates[0] + 2, coordinates[1] + 2),
                f"{prediction.confidence:.2f}",
                fill="#ff4fd8",
                font=font,
            )
        column = index % columns
        row = index // columns
        sheet.paste(tile, (column * tile_width, row * (title_height + body_height)))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output_path, quality=92, subsampling=0)


def write_metrics_csv(images: Sequence[OofImage], output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(
            stream,
            fieldnames=(
                "image_key",
                "fold",
                "ground_truth",
                "predictions",
                "misses",
                "false_positives",
                "mean_matched_iou",
                "latency_ms",
            ),
        )
        writer.writeheader()
        for record in images:
            writer.writerow(
                {
                    "image_key": record.image_key,
                    "fold": record.fold,
                    "ground_truth": len(record.ground_truth),
                    "predictions": len(record.predictions),
                    "misses": record.misses,
                    "false_positives": record.false_positives,
                    "mean_matched_iou": f"{record.mean_matched_iou:.9f}",
                    "latency_ms": f"{record.latency_ms:.3f}",
                }
            )


def _parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selection", required=True, type=Path)
    parser.add_argument("--image-root", required=True, type=Path)
    parser.add_argument("--source-prefix", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--columns", type=int, default=5)
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    args = _parse_args(argv)
    images = collect_source_images(args.selection, source_prefix=args.source_prefix)
    if len(images) != 30:
        raise ValueError(f"expected exactly 30 source images, found {len(images)}")
    render_contact_sheet(
        images,
        image_root=args.image_root,
        output_path=args.output / "contact_sheet.jpg",
        columns=args.columns,
    )
    write_metrics_csv(images, args.output / "per_image_metrics.csv")
    print(f"images={len(images)} output={args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
