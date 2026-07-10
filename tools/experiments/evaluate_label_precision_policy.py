import argparse
import json
import random
import time
from pathlib import Path

import cv2
import numpy as np
import torch
from PIL import Image, ImageDraw, ImageFont
from ultralytics import YOLO


IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def decode_image(path):
    data = np.fromfile(str(path), dtype=np.uint8)
    if data.size == 0:
        return None
    return cv2.imdecode(data, cv2.IMREAD_COLOR)


def encode_image(path, image):
    ok, data = cv2.imencode(".jpg", image, [int(cv2.IMWRITE_JPEG_QUALITY), 92])
    if not ok:
        raise RuntimeError(f"Failed to encode {path}")
    data.tofile(str(path))


def clamp_box(box, width, height, pad=0):
    x1, y1, x2, y2 = box
    x1 = max(0, int(round(x1 - pad)))
    y1 = max(0, int(round(y1 - pad)))
    x2 = min(width, int(round(x2 + pad)))
    y2 = min(height, int(round(y2 + pad)))
    if x2 <= x1 or y2 <= y1:
        return None
    return x1, y1, x2, y2


def crop_box(image, xyxy, pad_ratio=0.06):
    h, w = image.shape[:2]
    x1, y1, x2, y2 = xyxy
    pad = max(4, int(max(x2 - x1, y2 - y1) * pad_ratio))
    clamped = clamp_box((x1, y1, x2, y2), w, h, pad=pad)
    if clamped is None:
        return None
    x1, y1, x2, y2 = clamped
    return image[y1:y2, x1:x2]


def load_classes(data_dir):
    classes_path = data_dir / "classes.txt"
    if classes_path.exists():
        return [
            line.strip()
            for line in classes_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
    return sorted(path.name for path in (data_dir / "train").iterdir() if path.is_dir())


def class_image_paths(data_dir, class_name):
    paths = []
    for split in ["train", "val"]:
        class_dir = data_dir / split / class_name
        if class_dir.exists():
            paths.extend(
                path
                for path in class_dir.iterdir()
                if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES
            )
    return paths


def clip_embedding_model(model_name, pretrained):
    import open_clip

    model, _, preprocess = open_clip.create_model_and_transforms(
        model_name, pretrained=pretrained, device="cpu"
    )
    model.eval()
    return model, preprocess


@torch.inference_mode()
def encode_pil_images(model, preprocess, pil_images, batch_size=16):
    vectors = []
    for start in range(0, len(pil_images), batch_size):
        batch = pil_images[start : start + batch_size]
        tensor = torch.stack([preprocess(image.convert("RGB")) for image in batch])
        features = model.encode_image(tensor)
        features = features / features.norm(dim=-1, keepdim=True).clamp_min(1e-12)
        vectors.append(features.cpu())
    return torch.cat(vectors, dim=0)


def build_clip_prototypes(data_dir, classes, max_per_class, seed, model, preprocess):
    rng = random.Random(seed)
    prototypes = []
    counts = {}
    for class_name in classes:
        paths = class_image_paths(data_dir, class_name)
        rng.shuffle(paths)
        paths = paths[:max_per_class]
        images = []
        for path in paths:
            try:
                images.append(Image.open(path).convert("RGB"))
            except Exception:
                continue
        if not images:
            prototypes.append(torch.zeros(512))
            counts[class_name] = 0
            continue
        embeddings = encode_pil_images(model, preprocess, images)
        prototype = embeddings.mean(dim=0)
        prototype = prototype / prototype.norm().clamp_min(1e-12)
        prototypes.append(prototype)
        counts[class_name] = len(images)
    return torch.stack(prototypes, dim=0), counts


def clip_rank(model, preprocess, crop_bgr, prototypes, classes):
    rgb = cv2.cvtColor(crop_bgr, cv2.COLOR_BGR2RGB)
    pil = Image.fromarray(rgb)
    embedding = encode_pil_images(model, preprocess, [pil], batch_size=1)[0]
    scores = (embedding.unsqueeze(0) @ prototypes.T).squeeze(0)
    order = torch.argsort(scores, descending=True)
    top1 = int(order[0])
    top2 = int(order[1]) if len(order) > 1 else top1
    return {
        "clip_label": classes[top1],
        "clip_score": float(scores[top1].item()),
        "clip_margin": float((scores[top1] - scores[top2]).item()),
        "clip_second_label": classes[top2],
        "clip_second_score": float(scores[top2].item()),
    }


def yolo_classify(classifier, crops, classes):
    if not crops:
        return []
    results = classifier.predict(crops, imgsz=224, batch=16, verbose=False, device="cpu")
    output = []
    for result in results:
        probs = result.probs.data.detach().cpu().numpy()
        order = np.argsort(probs)[::-1]
        top1 = int(order[0])
        top2 = int(order[1]) if len(order) > 1 else top1
        output.append(
            {
                "predicted_label": classes[top1],
                "class_conf": float(probs[top1]),
                "class_margin": float(probs[top1] - probs[top2]),
                "second_label": classes[top2],
                "second_conf": float(probs[top2]),
            }
        )
    return output


def should_accept_label(class_info, clip_info, args):
    if class_info["predicted_label"] != clip_info["clip_label"]:
        return False
    if class_info["class_conf"] < args.class_conf:
        return False
    if class_info["class_margin"] < args.class_margin:
        return False
    if clip_info["clip_score"] < args.clip_score:
        return False
    if clip_info["clip_margin"] < args.clip_margin:
        return False
    return True


def draw_predictions(image_path, predictions, output_path):
    image = Image.open(image_path).convert("RGB")
    draw = ImageDraw.Draw(image)
    try:
        font = ImageFont.truetype("arial.ttf", 22)
    except Exception:
        font = ImageFont.load_default()
    for index, pred in enumerate(predictions, start=1):
        x, y, w, h = pred["x"], pred["y"], pred["w"], pred["h"]
        label = pred["accepted_label"] or "BOX_ONLY"
        color = (20, 185, 85) if pred["accepted_label"] else (235, 65, 65)
        draw.rectangle([x, y, x + w, y + h], outline=color, width=5)
        text = f"{index}:{label}"
        text_box = draw.textbbox((0, 0), text, font=font)
        text_w = text_box[2] - text_box[0]
        text_h = text_box[3] - text_box[1]
        tx, ty = int(x), max(0, int(y) - text_h - 8)
        draw.rectangle([tx, ty, tx + text_w + 8, ty + text_h + 6], fill=color)
        draw.text((tx + 4, ty + 3), text, fill=(255, 255, 255), font=font)
    image.save(output_path, quality=92)


def make_contact_sheet(image_paths, output_path, thumb_width=620):
    thumbs = []
    try:
        font = ImageFont.truetype("arial.ttf", 22)
    except Exception:
        font = ImageFont.load_default()
    for path in image_paths:
        image = Image.open(path).convert("RGB")
        scale = thumb_width / image.width
        thumb = image.resize((thumb_width, max(1, int(image.height * scale))))
        canvas = Image.new("RGB", (thumb.width, thumb.height + 36), (245, 245, 245))
        canvas.paste(thumb, (0, 36))
        draw = ImageDraw.Draw(canvas)
        draw.text((8, 7), path.name, fill=(20, 20, 20), font=font)
        thumbs.append(canvas)
    if not thumbs:
        return
    cols = 2
    rows = (len(thumbs) + cols - 1) // cols
    cell_w = max(thumb.width for thumb in thumbs)
    cell_h = max(thumb.height for thumb in thumbs)
    sheet = Image.new("RGB", (cell_w * cols, cell_h * rows), (235, 235, 235))
    for index, thumb in enumerate(thumbs):
        x = (index % cols) * cell_w
        y = (index // cols) * cell_h
        sheet.paste(thumb, (x, y))
    sheet.save(output_path, quality=92)


def run(args):
    args.output_dir.mkdir(parents=True, exist_ok=True)
    per_image_dir = args.output_dir / "images"
    per_image_dir.mkdir(exist_ok=True)

    classes = load_classes(args.classifier_data)
    detector = YOLO(str(args.detector))
    classifier = YOLO(str(args.classifier))

    clip_load_start = time.perf_counter()
    clip_model, clip_preprocess = clip_embedding_model(args.clip_model, args.clip_pretrained)
    prototypes, prototype_counts = build_clip_prototypes(
        args.classifier_data,
        classes,
        args.prototype_images,
        args.seed,
        clip_model,
        clip_preprocess,
    )
    clip_load_ms = (time.perf_counter() - clip_load_start) * 1000

    image_paths = sorted(
        path
        for path in args.input_dir.iterdir()
        if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES
    )
    summaries = []
    rendered_paths = []
    detector_times = []
    classifier_times = []
    clip_times = []

    for image_path in image_paths:
        image = decode_image(image_path)
        if image is None:
            continue
        h, w = image.shape[:2]
        start = time.perf_counter()
        det_result = detector.predict(
            str(image_path),
            imgsz=args.imgsz,
            conf=args.det_conf,
            iou=args.iou,
            verbose=False,
            device="cpu",
        )[0]
        detector_ms = (time.perf_counter() - start) * 1000
        detector_times.append(detector_ms)

        boxes = []
        for box in det_result.boxes:
            x1, y1, x2, y2 = box.xyxy[0].detach().cpu().numpy().tolist()
            conf = float(box.conf[0].detach().cpu().item())
            clamped = clamp_box((x1, y1, x2, y2), w, h)
            if clamped is None:
                continue
            x1, y1, x2, y2 = clamped
            bw, bh = x2 - x1, y2 - y1
            area_ratio = (bw * bh) / max(1, w * h)
            if bw < args.min_box_size or bh < args.min_box_size:
                continue
            if area_ratio > args.max_area_ratio:
                continue
            boxes.append({"xyxy": (x1, y1, x2, y2), "det_conf": conf})

        crops = [crop_box(image, item["xyxy"]) for item in boxes]
        valid = [(item, crop) for item, crop in zip(boxes, crops) if crop is not None]
        boxes = [item for item, _ in valid]
        crops = [crop for _, crop in valid]

        start = time.perf_counter()
        class_infos = yolo_classify(classifier, crops, classes)
        classifier_ms = (time.perf_counter() - start) * 1000
        classifier_times.append(classifier_ms)

        predictions = []
        start = time.perf_counter()
        for item, crop, class_info in zip(boxes, crops, class_infos):
            clip_info = clip_rank(clip_model, clip_preprocess, crop, prototypes, classes)
            accepted = should_accept_label(class_info, clip_info, args)
            x1, y1, x2, y2 = item["xyxy"]
            pred = {
                "x": float(x1),
                "y": float(y1),
                "w": float(x2 - x1),
                "h": float(y2 - y1),
                "det_conf": item["det_conf"],
                "accepted_label": class_info["predicted_label"] if accepted else None,
            }
            pred.update(class_info)
            pred.update(clip_info)
            predictions.append(pred)
        clip_ms = (time.perf_counter() - start) * 1000
        clip_times.append(clip_ms)

        rendered_path = per_image_dir / f"{image_path.stem}_policy_clip.jpg"
        draw_predictions(image_path, predictions, rendered_path)
        rendered_paths.append(rendered_path)
        summaries.append(
            {
                "image": image_path.name,
                "detector_ms": round(detector_ms, 1),
                "classifier_ms": round(classifier_ms, 1),
                "clip_ms": round(clip_ms, 1),
                "boxes": len(predictions),
                "auto_labeled": sum(1 for pred in predictions if pred["accepted_label"]),
                "box_only": sum(1 for pred in predictions if not pred["accepted_label"]),
                "predictions": predictions,
            }
        )

    totals = {
        "images": len(summaries),
        "boxes": sum(item["boxes"] for item in summaries),
        "auto_labeled": sum(item["auto_labeled"] for item in summaries),
        "box_only": sum(item["box_only"] for item in summaries),
        "avg_detector_ms": round(float(np.mean(detector_times)) if detector_times else 0.0, 1),
        "avg_classifier_ms": round(float(np.mean(classifier_times)) if classifier_times else 0.0, 1),
        "avg_clip_ms": round(float(np.mean(clip_times)) if clip_times else 0.0, 1),
        "clip_load_and_prototype_ms": round(clip_load_ms, 1),
    }
    summary = {
        "policy": {
            "det_conf": args.det_conf,
            "class_conf": args.class_conf,
            "class_margin": args.class_margin,
            "clip_score": args.clip_score,
            "clip_margin": args.clip_margin,
            "prototype_images_per_class": args.prototype_images,
            "clip_model": args.clip_model,
            "clip_pretrained": args.clip_pretrained,
            "intent": "High recall boxes; zero-tolerance automatic labels.",
        },
        "totals": totals,
        "prototype_counts": prototype_counts,
        "images": summaries,
    }
    summary_path = args.output_dir / "bread_policy_clip_summary.json"
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    make_contact_sheet(rendered_paths, args.output_dir / "bread_policy_clip_contact_sheet.jpg")
    print(json.dumps({"summary": str(summary_path), "totals": totals}, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--input-dir",
        type=Path,
        default=Path(r"C:\workspace\bbox\datasets\bread_eval_samples\images"),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(r"C:\workspace\bbox\outputs\experiments\bread_policy_clip"),
    )
    parser.add_argument(
        "--detector",
        type=Path,
        default=Path(r"C:\workspace\bbox\models\bread_yolov8n_1class_best.pt"),
    )
    parser.add_argument(
        "--classifier",
        type=Path,
        default=Path(
            r"C:\workspace\bbox\models\bread_classifier_yolov8n_cls_best.pt"
        ),
    )
    parser.add_argument(
        "--classifier-data",
        type=Path,
        default=Path(r"C:\workspace\bbox\datasets\bread_classifier_v0_1"),
    )
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--det-conf", type=float, default=0.35)
    parser.add_argument("--iou", type=float, default=0.55)
    parser.add_argument("--min-box-size", type=int, default=45)
    parser.add_argument("--max-area-ratio", type=float, default=0.38)
    parser.add_argument("--class-conf", type=float, default=0.97)
    parser.add_argument("--class-margin", type=float, default=0.40)
    parser.add_argument("--clip-score", type=float, default=0.60)
    parser.add_argument("--clip-margin", type=float, default=0.015)
    parser.add_argument("--clip-model", default="ViT-B-32")
    parser.add_argument("--clip-pretrained", default="openai")
    parser.add_argument("--prototype-images", type=int, default=8)
    parser.add_argument("--seed", type=int, default=20260710)
    args = parser.parse_args()
    run(args)


if __name__ == "__main__":
    main()
