import argparse
import csv
import random
from pathlib import Path

import cv2
import numpy as np


SUPPORTED_IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def supported_image_paths(directory):
    if directory is None or not directory.exists():
        return []
    return sorted(
        path
        for path in directory.rglob("*")
        if path.is_file() and path.suffix.lower() in SUPPORTED_IMAGE_SUFFIXES
    )


def read_manifest(path):
    with path.open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def decode_image(path):
    data = np.fromfile(str(path), dtype=np.uint8)
    if data.size == 0:
        return None
    return cv2.imdecode(data, cv2.IMREAD_COLOR)


def resize_to_square(image, size):
    height, width = image.shape[:2]
    if height <= 0 or width <= 0:
        raise ValueError("image must have positive dimensions")
    scale = size / max(height, width)
    new_width = max(1, int(round(width * scale)))
    new_height = max(1, int(round(height * scale)))
    resized = cv2.resize(image, (new_width, new_height), interpolation=cv2.INTER_AREA)
    canvas = np.zeros((size, size, 3), dtype=np.uint8)
    x = (size - new_width) // 2
    y = (size - new_height) // 2
    canvas[y : y + new_height, x : x + new_width] = resized
    return canvas


def write_empty_yolo_label(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("", encoding="utf-8")


def write_dataset_yaml(output):
    yaml_path = output / "dataset.yaml"
    yaml_path.write_text(
        "\n".join(
            [
                f"path: {output.resolve().as_posix()}",
                "train: images/train",
                "val: images/val",
                "names:",
                "  0: bread",
                "",
            ]
        ),
        encoding="utf-8",
    )
    return yaml_path


def add_negative_images(
    output,
    split,
    source_paths,
    count,
    size,
    rng,
    prefix="negative",
):
    if count <= 0 or not source_paths:
        return 0

    image_dir = output / "images" / split
    label_dir = output / "labels" / split
    image_dir.mkdir(parents=True, exist_ok=True)
    label_dir.mkdir(parents=True, exist_ok=True)

    written = 0
    for index in range(count):
        source_path = rng.choice(source_paths)
        image = decode_image(source_path)
        if image is None:
            continue
        canvas = resize_to_square(image, size)
        stem = f"{prefix}_{index:05d}"
        image_path = image_dir / f"{stem}.jpg"
        label_path = label_dir / f"{stem}.txt"
        cv2.imencode(".jpg", canvas, [int(cv2.IMWRITE_JPEG_QUALITY), 92])[1].tofile(
            str(image_path)
        )
        write_empty_yolo_label(label_path)
        written += 1
    return written


def bread_mask(image):
    hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)
    h, s, v = cv2.split(hsv)
    b, g, r = cv2.split(image)
    maxc = np.maximum.reduce([b, g, r])
    minc = np.minimum.reduce([b, g, r])
    chroma = maxc - minc

    warm_hue = ((h <= 42) | (h >= 168)) & (s >= 18) & (v >= 45)
    warm_rgb = (
        (r.astype(np.int16) > g.astype(np.int16) - 8)
        & (r.astype(np.int16) > b.astype(np.int16) + 12)
        & (v >= 55)
        & (chroma >= 14)
    )
    mask = (warm_hue | warm_rgb).astype(np.uint8) * 255

    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (9, 9))
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel, iterations=2)
    return clean_bread_mask(mask)


def keep_largest_mask_component(mask):
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return mask
    largest = max(contours, key=cv2.contourArea)
    cleaned = np.zeros_like(mask)
    cv2.drawContours(cleaned, [largest], -1, 255, -1)
    return cleaned


def clean_bread_mask(mask):
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    cleaned = cv2.morphologyEx(mask, cv2.MORPH_OPEN, kernel)
    cleaned = cv2.morphologyEx(cleaned, cv2.MORPH_CLOSE, kernel, iterations=2)
    return keep_largest_mask_component(cleaned)


def largest_object_bbox(mask, min_area_ratio=0.0006):
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    image_area = mask.shape[0] * mask.shape[1]
    candidates = []
    for contour in contours:
        area = cv2.contourArea(contour)
        if area < image_area * min_area_ratio:
            continue
        x, y, w, h = cv2.boundingRect(contour)
        if w >= 20 and h >= 20:
            candidates.append((area, x, y, w, h))
    if not candidates:
        return None
    _, x, y, w, h = max(candidates, key=lambda item: item[0])
    return x, y, w, h


def extract_cutout(image_path):
    image = decode_image(image_path)
    if image is None:
        return None
    h, w = image.shape[:2]
    longest = max(h, w)
    if longest > 1200:
        scale = 1200 / longest
        image = cv2.resize(
            image,
            (max(1, int(w * scale)), max(1, int(h * scale))),
            interpolation=cv2.INTER_AREA,
        )
    mask = bread_mask(image)
    bbox = largest_object_bbox(mask)
    if bbox is None:
        return None

    x, y, bw, bh = bbox
    pad = max(8, int(max(bw, bh) * 0.08))
    x1 = max(0, x - pad)
    y1 = max(0, y - pad)
    x2 = min(image.shape[1], x + bw + pad)
    y2 = min(image.shape[0], y + bh + pad)
    crop = image[y1:y2, x1:x2].copy()
    crop_mask = mask[y1:y2, x1:x2]
    ys, xs = np.where(crop_mask > 0)
    if crop.size == 0 or xs.size == 0 or ys.size == 0:
        return None

    alpha = cv2.GaussianBlur(crop_mask, (7, 7), 0).astype(np.float32) / 255.0
    crop = (alpha[:, :, None] * crop).astype(np.uint8)
    object_bbox = (
        int(xs.min()),
        int(ys.min()),
        int(xs.max() - xs.min() + 1),
        int(ys.max() - ys.min() + 1),
    )
    if not cutout_is_usable(crop, alpha):
        return None
    return crop, alpha, object_bbox


def make_cutout_contact_sheet(cutouts, output, tile_size=160, columns=5):
    if not cutouts:
        return 0
    output.parent.mkdir(parents=True, exist_ok=True)
    tiles = []
    for crop, alpha, object_bbox in cutouts:
        preview = crop.copy()
        if preview.ndim == 2:
            preview = cv2.cvtColor(preview, cv2.COLOR_GRAY2BGR)
        alpha_mask = (np.clip(alpha, 0, 1) * 255).astype(np.uint8)
        outline, _ = cv2.findContours(
            alpha_mask,
            cv2.RETR_EXTERNAL,
            cv2.CHAIN_APPROX_SIMPLE,
        )
        cv2.drawContours(preview, outline, -1, (0, 255, 0), 1)
        x, y, width, height = [int(round(value)) for value in object_bbox]
        cv2.rectangle(preview, (x, y), (x + width, y + height), (0, 255, 255), 1)
        tile = resize_to_square(preview, tile_size)
        tiles.append(tile)

    rows = []
    blank = np.zeros((tile_size, tile_size, 3), dtype=np.uint8)
    for start in range(0, len(tiles), columns):
        row_tiles = tiles[start : start + columns]
        row_tiles += [blank.copy() for _ in range(columns - len(row_tiles))]
        rows.append(np.hstack(row_tiles))
    sheet = np.vstack(rows)
    cv2.imwrite(str(output), sheet)
    return len(cutouts)


def cutout_warm_pixel_ratio(crop, alpha):
    pixels = crop[alpha > 0.5]
    if pixels.size == 0:
        return 0.0
    b = pixels[:, 0].astype(np.int16)
    g = pixels[:, 1].astype(np.int16)
    r = pixels[:, 2].astype(np.int16)
    maxc = np.maximum.reduce([b, g, r])
    minc = np.minimum.reduce([b, g, r])
    chroma = maxc - minc
    warm = (r > g - 8) & (r > b + 12) & (maxc >= 55) & (chroma >= 14)
    return float(warm.mean())


def cutout_is_usable(crop, alpha, min_warm_ratio=0.45):
    return cutout_warm_pixel_ratio(crop, alpha) >= min_warm_ratio


def make_background(size, rng):
    base = np.zeros((size, size, 3), dtype=np.uint8)
    shade = rng.randint(18, 42)
    base[:] = (shade, shade + rng.randint(-3, 8), shade + rng.randint(-2, 8))

    if rng.random() < 0.8:
        tray_color = np.array(
            [rng.randint(115, 165), rng.randint(135, 185), rng.randint(150, 205)],
            dtype=np.uint8,
        )
        margin = rng.randint(45, 95)
        cv2.rectangle(
            base,
            (margin, margin),
            (size - margin, size - margin),
            tray_color.tolist(),
            -1,
        )
        for offset in range(margin + 10, size - margin, 22):
            color = tuple(int(c) for c in (tray_color * rng.uniform(0.72, 1.12)))
            cv2.line(base, (margin, offset), (size - margin, offset), color, 1)

    if rng.random() < 0.9:
        paper = np.array(
            [rng.randint(188, 220), rng.randint(192, 224), rng.randint(196, 230)],
            dtype=np.uint8,
        )
        px1 = rng.randint(85, 140)
        py1 = rng.randint(90, 150)
        px2 = size - rng.randint(80, 135)
        py2 = size - rng.randint(90, 140)
        cv2.rectangle(base, (px1, py1), (px2, py2), paper.tolist(), -1)

    jitter = np.random.default_rng(rng.randint(0, 2**31 - 1)).normal(0, 3, base.shape)
    return np.clip(base.astype(np.float32) + jitter, 0, 255).astype(np.uint8)


def load_template_backgrounds(directory, size):
    templates = []
    for path in supported_image_paths(directory):
        image = decode_image(path)
        if image is None:
            continue
        templates.append(resize_to_square(image, size))
    return templates


def make_template_background(template, rng):
    canvas = template.copy()
    alpha = rng.uniform(0.88, 1.12)
    beta = rng.randint(-10, 10)
    canvas = np.clip(canvas.astype(np.float32) * alpha + beta, 0, 255).astype(np.uint8)
    if rng.random() < 0.25:
        canvas = cv2.GaussianBlur(canvas, (3, 3), 0)
    jitter = np.random.default_rng(rng.randint(0, 2**31 - 1)).normal(
        0,
        2,
        canvas.shape,
    )
    return np.clip(canvas.astype(np.float32) + jitter, 0, 255).astype(np.uint8)


def make_canvas(args, rng, templates):
    if templates and rng.random() < args.template_probability:
        return make_template_background(rng.choice(templates), rng)
    return make_background(args.size, rng)


def paste_cutout(canvas, cutout, alpha, object_bbox, rng, placement_margin_ratio=0.0):
    size = canvas.shape[0]
    ch, cw = cutout.shape[:2]
    target_long = rng.randint(110, 245)
    scale = target_long / max(ch, cw)
    new_w = max(24, int(cw * scale))
    new_h = max(24, int(ch * scale))
    if new_w >= size - 20 or new_h >= size - 20:
        factor = min((size - 30) / new_w, (size - 30) / new_h)
        new_w = max(24, int(new_w * factor))
        new_h = max(24, int(new_h * factor))

    resized = cv2.resize(cutout, (new_w, new_h), interpolation=cv2.INTER_AREA)
    resized_alpha = cv2.resize(alpha, (new_w, new_h), interpolation=cv2.INTER_AREA)
    if rng.random() < 0.45:
        resized = cv2.flip(resized, 1)
        resized_alpha = cv2.flip(resized_alpha, 1)
        ox, oy, ow, oh = object_bbox
        object_bbox = (cw - ox - ow, oy, ow, oh)

    margin = int(size * placement_margin_ratio)
    min_x = max(8, margin)
    min_y = max(8, margin)
    max_x = size - new_w - min_x
    max_y = size - new_h - min_y
    if max_x <= min_x or max_y <= min_y:
        return None
    x = rng.randint(min_x, max_x)
    y = rng.randint(min_y, max_y)

    roi = canvas[y : y + new_h, x : x + new_w]
    alpha3 = resized_alpha[:, :, None]
    roi[:] = (alpha3 * resized + (1.0 - alpha3) * roi).astype(np.uint8)

    bx, by, bw, bh = object_bbox
    sx = new_w / cw
    sy = new_h / ch
    return x + bx * sx, y + by * sy, bw * sx, bh * sy


def box_overlap_ratio(candidate, existing):
    cx, cy, cw, ch = candidate
    ex, ey, ew, eh = existing
    width = max(0.0, min(cx + cw, ex + ew) - max(cx, ex))
    height = max(0.0, min(cy + ch, ey + eh) - max(cy, ey))
    candidate_area = max(0.0, cw) * max(0.0, ch)
    if candidate_area <= 0:
        return 0.0
    return (width * height) / candidate_area


def box_overlaps_existing(candidate, existing_boxes, max_overlap_ratio):
    return any(
        box_overlap_ratio(candidate, existing) > max_overlap_ratio
        for existing in existing_boxes
    )


def write_yolo_label(path, boxes, size):
    lines = []
    for x, y, w, h in boxes:
        cx = (x + w / 2) / size
        cy = (y + h / 2) / size
        nw = w / size
        nh = h / size
        lines.append(f"0 {cx:.6f} {cy:.6f} {nw:.6f} {nh:.6f}")
    path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def build_dataset(args):
    rng = random.Random(args.seed)
    rows = read_manifest(args.manifest)
    cutouts = []
    for row in rows:
        item = extract_cutout(args.image_root / row["relative_path"])
        if item is not None:
            cutouts.append(item)
    if len(cutouts) < 20:
        raise RuntimeError(f"Only {len(cutouts)} usable cutouts were extracted.")
    if args.cutout_contact_sheet is not None:
        make_cutout_contact_sheet(
            cutouts[: args.cutout_contact_sheet_limit],
            args.cutout_contact_sheet,
        )
    templates = load_template_backgrounds(args.tray_template_dir, args.size)

    for split, count in [("train", args.train), ("val", args.val)]:
        image_dir = args.output / "images" / split
        label_dir = args.output / "labels" / split
        image_dir.mkdir(parents=True, exist_ok=True)
        label_dir.mkdir(parents=True, exist_ok=True)
        for index in range(count):
            canvas = make_canvas(args, rng, templates)
            boxes = []
            for _ in range(rng.randint(args.min_objects, args.max_objects)):
                for _ in range(args.placement_attempts):
                    box = paste_cutout(
                        canvas,
                        *rng.choice(cutouts),
                        rng,
                        placement_margin_ratio=args.placement_margin_ratio
                        if templates
                        else 0.0,
                    )
                    if box is None or box[2] < 8 or box[3] < 8:
                        continue
                    if box_overlaps_existing(
                        box,
                        boxes,
                        args.max_placement_overlap,
                    ):
                        continue
                    boxes.append(box)
                    break
            stem = f"{split}_{index:05d}"
            image_path = image_dir / f"{stem}.jpg"
            label_path = label_dir / f"{stem}.txt"
            cv2.imencode(".jpg", canvas, [int(cv2.IMWRITE_JPEG_QUALITY), 92])[
                1
            ].tofile(str(image_path))
            write_yolo_label(label_path, boxes, args.size)

    negative_paths = supported_image_paths(args.negative_image_dir)
    train_negatives = add_negative_images(
        args.output,
        "train",
        negative_paths,
        args.negative_train,
        args.size,
        rng,
    )
    val_negatives = add_negative_images(
        args.output,
        "val",
        negative_paths,
        args.negative_val,
        args.size,
        rng,
    )
    yaml_path = write_dataset_yaml(args.output)
    print(
        f"cutouts={len(cutouts)} templates={len(templates)} "
        f"train_negatives={train_negatives} val_negatives={val_negatives}"
    )
    print(yaml_path.resolve())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path(
            r"C:\workspace\bakery_vision\data\manifests\bixolon_bakery_raw_v0.1.0.csv"
        ),
    )
    parser.add_argument(
        "--image-root",
        type=Path,
        default=Path(r"C:\workspace\bakery_vision\data\raw\bixolon_bakery\images"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(
            r"C:\workspace\bbox\outputs\training\bixolon_bread_yolo_synth_v0.1.0"
        ),
    )
    parser.add_argument("--train", type=int, default=800)
    parser.add_argument("--val", type=int, default=160)
    parser.add_argument("--size", type=int, default=640)
    parser.add_argument("--min-objects", type=int, default=3)
    parser.add_argument("--max-objects", type=int, default=8)
    parser.add_argument("--negative-image-dir", type=Path)
    parser.add_argument("--negative-train", type=int, default=0)
    parser.add_argument("--negative-val", type=int, default=0)
    parser.add_argument("--tray-template-dir", type=Path)
    parser.add_argument("--template-probability", type=float, default=0.75)
    parser.add_argument("--placement-margin-ratio", type=float, default=0.12)
    parser.add_argument("--placement-attempts", type=int, default=12)
    parser.add_argument("--max-placement-overlap", type=float, default=0.28)
    parser.add_argument("--cutout-contact-sheet", type=Path)
    parser.add_argument("--cutout-contact-sheet-limit", type=int, default=30)
    parser.add_argument("--seed", type=int, default=20260709)
    args = parser.parse_args()
    build_dataset(args)


if __name__ == "__main__":
    main()
