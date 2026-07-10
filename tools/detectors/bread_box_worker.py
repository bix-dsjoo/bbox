import argparse
import contextlib
import json
import struct
import sys
from pathlib import Path


PROTOCOL_VERSION = 1
MAX_HEADER_BYTES = 64 * 1024
MAX_IMAGE_BYTES = 512 * 1024 * 1024
MAX_RESPONSE_BYTES = 1024 * 1024


class DecodeError(Exception):
    pass


def read_exact(stream, length):
    chunks = bytearray()
    while len(chunks) < length:
        chunk = stream.read(length - len(chunks))
        if not chunk:
            raise EOFError(f"expected {length} bytes, received {len(chunks)}")
        chunks.extend(chunk)
    return bytes(chunks)


def read_request(stream):
    prefix = stream.read(4)
    if prefix == b"":
        return None
    if len(prefix) != 4:
        raise EOFError("truncated request header length")
    header_length = struct.unpack(">I", prefix)[0]
    if header_length > MAX_HEADER_BYTES:
        raise ValueError("request header exceeds 64 KiB")
    header = json.loads(read_exact(stream, header_length).decode("utf-8"))
    payload_length = struct.unpack(">Q", read_exact(stream, 8))[0]
    if payload_length > MAX_IMAGE_BYTES:
        raise ValueError("image payload exceeds 512 MiB")
    return header, read_exact(stream, payload_length)


def write_json_frame(stream, payload):
    encoded = json.dumps(
        payload, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    if len(encoded) > MAX_RESPONSE_BYTES:
        raise ValueError("response exceeds 1 MiB")
    stream.write(struct.pack(">I", len(encoded)))
    stream.write(encoded)
    stream.flush()


class BreadBoxEngine:
    def __init__(self, args, cv2, np, yolo_factory):
        self.args = args
        self.cv2 = cv2
        self.np = np
        self.detector = yolo_factory(args.detector_model)

    def detect_bytes(self, payload, max_proposals=None):
        encoded = self.np.frombuffer(payload, dtype=self.np.uint8)
        try:
            image = self.cv2.imdecode(encoded, self.cv2.IMREAD_COLOR)
        except self.cv2.error as error:
            raise DecodeError("Image could not be decoded.") from error
        if image is None:
            raise DecodeError("Image could not be decoded.")

        with contextlib.redirect_stdout(sys.stderr):
            detection = self.detector.predict(
                image,
                imgsz=self.args.imgsz,
                conf=self.args.det_conf,
                iou=self.args.iou,
                device="cpu",
                verbose=False,
            )[0]

        image_height, image_width = image.shape[:2]
        limit = self.args.max_results if max_proposals is None else int(max_proposals)
        boxes = _extract_detection_boxes(
            detection,
            image_width=image_width,
            image_height=image_height,
            min_box_size=self.args.min_box_size,
            max_area_ratio=self.args.max_area_ratio,
            max_results=max(0, limit),
        )
        return {
            "width": image_width,
            "height": image_height,
            "boxes": [_json_box(item) for item in boxes],
        }


def serve(stdin, stdout, engine):
    while True:
        request = read_request(stdin)
        if request is None:
            return 0
        header, payload = request
        request_id = str(header.get("requestId", ""))
        if header.get("version") != PROTOCOL_VERSION:
            raise ValueError("unsupported protocol version")
        if header.get("type") == "shutdown":
            return 0
        try:
            result = engine.detect_bytes(payload, header.get("maxProposals"))
            write_json_frame(
                stdout,
                {
                    "version": PROTOCOL_VERSION,
                    "type": "result",
                    "requestId": request_id,
                    "image": {
                        "width": result["width"],
                        "height": result["height"],
                    },
                    "boxes": result["boxes"],
                },
            )
        except DecodeError as error:
            write_json_frame(
                stdout,
                {
                    "version": PROTOCOL_VERSION,
                    "type": "error",
                    "requestId": request_id,
                    "code": "decode_failed",
                    "message": str(error),
                },
            )
        except Exception as error:
            write_json_frame(
                stdout,
                {
                    "version": PROTOCOL_VERSION,
                    "type": "error",
                    "requestId": request_id,
                    "code": "inference_failed",
                    "message": str(error),
                },
            )


def _extract_detection_boxes(
    result,
    *,
    image_width,
    image_height,
    min_box_size,
    max_area_ratio,
    max_results,
):
    if result.boxes is None:
        return []
    image_area = max(1, image_width * image_height)
    raw_xyxy = result.boxes.xyxy.cpu().numpy()
    confidences = result.boxes.conf.cpu().numpy()
    boxes = []
    for index, row in enumerate(raw_xyxy):
        x1, y1, x2, y2 = [float(value) for value in row]
        x1 = max(0.0, min(x1, float(image_width)))
        y1 = max(0.0, min(y1, float(image_height)))
        x2 = max(0.0, min(x2, float(image_width)))
        y2 = max(0.0, min(y2, float(image_height)))
        width = x2 - x1
        height = y2 - y1
        if width < min_box_size or height < min_box_size:
            continue
        if (width * height) / image_area > max_area_ratio:
            continue
        boxes.append(
            {
                "xyxy": (x1, y1, x2, y2),
                "confidence": round(float(confidences[index]), 4),
            }
        )
    boxes = _nms(boxes, iou_threshold=0.85)
    boxes = _remove_aggregate_boxes(boxes)
    boxes.sort(key=lambda item: (item["xyxy"][1], item["xyxy"][0]))
    return boxes[:max_results]


def _json_box(box):
    x1, y1, x2, y2 = box["xyxy"]
    return {
        "x": round(float(x1), 2),
        "y": round(float(y1), 2),
        "width": round(float(x2 - x1), 2),
        "height": round(float(y2 - y1), 2),
        "confidence": box["confidence"],
    }


def _nms(boxes, *, iou_threshold):
    ordered = sorted(
        boxes,
        key=lambda item: (item["confidence"], _area(item)),
        reverse=True,
    )
    selected = []
    for candidate in ordered:
        if all(_iou(candidate, kept) < iou_threshold for kept in selected):
            selected.append(candidate)
    return selected


def _remove_aggregate_boxes(
    boxes,
    *,
    min_supporting_boxes=2,
    min_supported_overlap=0.20,
    min_coverage=0.35,
    single_support_coverage=0.16,
    low_confidence_aggregate=0.65,
    high_confidence_keep=0.80,
):
    filtered = []
    for candidate in boxes:
        candidate_area = _area(candidate)
        if candidate_area <= 0 or candidate["confidence"] >= high_confidence_keep:
            filtered.append(candidate)
            continue

        supporting = []
        covered_area = 0.0
        for other in boxes:
            if other is candidate:
                continue
            other_area = _area(other)
            if other_area <= 0 or other_area >= candidate_area:
                continue
            intersection = _intersection(candidate, other)
            if intersection / other_area < min_supported_overlap:
                continue
            supporting.append(other)
            covered_area += intersection

        if (
            len(supporting) >= min_supporting_boxes
            and covered_area / candidate_area >= min_coverage
        ):
            continue
        if (
            len(supporting) == 1
            and candidate["confidence"] < low_confidence_aggregate
            and covered_area / candidate_area >= single_support_coverage
        ):
            continue
        filtered.append(candidate)
    return filtered


def _area(box):
    x1, y1, x2, y2 = box["xyxy"]
    return max(0.0, x2 - x1) * max(0.0, y2 - y1)


def _intersection(a, b):
    ax1, ay1, ax2, ay2 = a["xyxy"]
    bx1, by1, bx2, by2 = b["xyxy"]
    width = max(0.0, min(ax2, bx2) - max(ax1, bx1))
    height = max(0.0, min(ay2, by2) - max(ay1, by1))
    return width * height


def _iou(a, b):
    intersection = _intersection(a, b)
    union = _area(a) + _area(b) - intersection
    return 0.0 if union <= 0 else intersection / union


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Persistent CPU bread detector that emits coordinate-only boxes."
    )
    parser.add_argument("--detector-model", required=True)
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--det-conf", type=float, default=0.40)
    parser.add_argument("--iou", type=float, default=0.55)
    parser.add_argument("--max-results", type=int, default=50)
    parser.add_argument("--min-box-size", type=int, default=45)
    parser.add_argument("--max-area-ratio", type=float, default=0.38)
    args = parser.parse_args()

    try:
        with contextlib.redirect_stdout(sys.stderr):
            import cv2
            import numpy as np
            from ultralytics import YOLO
    except Exception as error:
        print(f"Bread detector dependencies are unavailable: {error}", file=sys.stderr)
        return 3

    try:
        with contextlib.redirect_stdout(sys.stderr):
            engine = BreadBoxEngine(args, cv2, np, YOLO)
    except Exception as error:
        print(f"Bread detector initialization failed: {error}", file=sys.stderr)
        return 5

    write_json_frame(
        sys.stdout.buffer,
        {
            "version": PROTOCOL_VERSION,
            "type": "ready",
            "detectorName": "bread-yolo-boxes",
            "model": Path(args.detector_model).name,
        },
    )
    return serve(sys.stdin.buffer, sys.stdout.buffer, engine)


if __name__ == "__main__":
    raise SystemExit(main())
