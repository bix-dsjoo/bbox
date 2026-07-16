import argparse
import contextlib
import hashlib
import inspect
import json
import math
import struct
import sys
from pathlib import Path

try:
    from tools.detectors.bread_label_policy import (
        classify_policy,
        is_ambiguous_scores,
        normalized_scores,
    )
    from tools.detectors.bread_pipeline_manifest import (
        load_pipeline_manifest,
        resolve_model_paths,
    )
except ModuleNotFoundError:  # Direct execution from tools/detectors.
    from bread_label_policy import (  # type: ignore[no-redef]
        classify_policy,
        is_ambiguous_scores,
        normalized_scores,
    )
    from bread_pipeline_manifest import (  # type: ignore[no-redef]
        load_pipeline_manifest,
        resolve_model_paths,
    )


PROTOCOL_VERSION = 2
MAX_HEADER_BYTES = 64 * 1024
MAX_IMAGE_BYTES = 64 * 1024 * 1024
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


def read_prefix_exact(stream):
    first = stream.read(1)
    if first == b"":
        return None
    prefix = bytearray(first)
    while len(prefix) < 4:
        chunk = stream.read(4 - len(prefix))
        if not chunk:
            raise EOFError(f"expected 4 bytes, received {len(prefix)}")
        prefix.extend(chunk)
    return bytes(prefix)


def read_payload_exact(stream, length):
    payload = bytearray(length)
    view = memoryview(payload)
    offset = 0
    readinto = getattr(stream, "readinto", None)
    while offset < length:
        if callable(readinto):
            count = readinto(view[offset:])
        else:
            chunk = stream.read(min(length - offset, 1024 * 1024))
            count = len(chunk) if chunk else 0
            if count:
                view[offset : offset + count] = chunk
        if count is None or count <= 0:
            raise EOFError(f"expected {length} bytes, received {offset}")
        offset += count
    return payload


def read_request(stream):
    prefix = read_prefix_exact(stream)
    if prefix is None:
        return None
    header_length = struct.unpack(">I", prefix)[0]
    if header_length > MAX_HEADER_BYTES:
        raise ValueError("request header exceeds 64 KiB")
    encoded_header = read_exact(stream, header_length)
    payload_length = struct.unpack(">Q", read_exact(stream, 8))[0]
    if payload_length > MAX_IMAGE_BYTES:
        raise ValueError("image payload exceeds 64 MiB")
    payload = read_payload_exact(stream, payload_length)
    try:
        header = json.loads(
            encoded_header.decode("utf-8"),
            parse_constant=lambda value: (_ for _ in ()).throw(
                ValueError(f"non-finite JSON constant: {value}")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise ValueError("request header must be a valid JSON object") from error
    if not isinstance(header, dict):
        raise ValueError("request header must be a valid JSON object")
    return header, payload


def write_json_frame(stream, payload):
    encoded = json.dumps(
        payload,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
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


class BreadInferenceEngine:
    """Manifest-driven detector and crop-classifier pipeline.

    Model objects are injected after construction by the factory and are retained
    for the lifetime of the worker. Coordinates entering and leaving this class
    are always original-image pixels.
    """

    def __init__(
        self,
        manifest,
        cv2,
        np,
        detector,
        classifier,
        verifier,
        *,
        classifier_error=None,
        verifier_error=None,
    ):
        self.manifest = manifest
        self.cv2 = cv2
        self.np = np
        self.detector = detector
        self.classifier = classifier
        self.verifier = verifier
        self.classifier_error = classifier_error
        self.verifier_error = verifier_error

    def detect_bytes(self, payload, max_proposals=None):
        image = self._decode(payload)
        image_height, image_width = image.shape[:2]
        with contextlib.redirect_stdout(sys.stderr):
            detection = self.detector.predict(
                image,
                imgsz=self.manifest.detector["imgsz"],
                conf=self.manifest.detector["confidence"],
                iou=self.manifest.detector["iou"],
                device="cpu",
                verbose=False,
            )[0]
        boxes, detector_errors = _pipeline_detection_boxes(
            detection, image_width=image_width, image_height=image_height
        )
        boxes = _nms(boxes, iou_threshold=0.85)
        boxes.sort(key=lambda item: (item["xyxy"][1], item["xyxy"][0]))
        if max_proposals is not None:
            boxes = boxes[: max(0, int(max_proposals))]
        return self._classify_result(
            payload, image, boxes, initial_stage_errors=detector_errors
        )

    def classify_bytes(self, payload, boxes):
        image = self._decode(payload)
        image_height, image_width = image.shape[:2]
        normalized = []
        for item in boxes:
            box = _supplied_pipeline_box(
                item, image_width=image_width, image_height=image_height
            )
            if box is not None:
                normalized.append(box)
        return self._classify_result(payload, image, normalized)

    def _decode(self, payload):
        encoded = self.np.frombuffer(payload, dtype=self.np.uint8)
        try:
            image = self.cv2.imdecode(encoded, self.cv2.IMREAD_COLOR)
        except self.cv2.error as error:
            raise DecodeError("Image could not be decoded.") from error
        if image is None:
            raise DecodeError("Image could not be decoded.")
        return image

    def _classify_result(self, payload, image, boxes, *, initial_stage_errors=()):
        image_height, image_width = image.shape[:2]
        decisions, classifier_errors = self._classify_crops(
            image, boxes, image_width=image_width, image_height=image_height
        )
        stage_errors = [*initial_stage_errors, *classifier_errors]
        json_boxes = []
        for box, decision in zip(boxes, decisions):
            label = decision
            if box.get("edge_clipped"):
                label = _add_review_reason(label, "edge_clipped")
            json_boxes.append(_json_pipeline_box(box, label))
        _apply_duplicate_review(
            json_boxes, float(self.manifest.quality["duplicateIou"])
        )
        digest = hashlib.sha256(payload).hexdigest()
        return {
            # Keep these fields for the existing v1 serve adapter until Task 4.
            "width": image_width,
            "height": image_height,
            "image": {
                "width": image_width,
                "height": image_height,
                "sha256": digest,
            },
            "boxes": json_boxes,
            "stageErrors": stage_errors,
        }

    def _classify_crops(self, image, boxes, *, image_width, image_height):
        if not boxes:
            return [], []
        if self.classifier is None:
            message = self.classifier_error or "classifier unavailable"
            return (
                [_unavailable_label(message) for _ in boxes],
                [_stage_error("classifier", message)],
            )
        crops = [_crop_box(image, item["xyxy"]) for item in boxes]
        try:
            with contextlib.redirect_stdout(sys.stderr):
                results = self.classifier.predict(
                    crops,
                    imgsz=self.manifest.classifier["imgsz"],
                    batch=min(16, len(crops)),
                    verbose=False,
                    device="cpu",
                )
            if len(results) != len(boxes):
                raise RuntimeError("classifier returned an unexpected result count")
            decisions = []
            verifier_was_needed = False
            for box, crop, result in zip(boxes, crops, results):
                raw_scores = result.probs.data
                if hasattr(raw_scores, "cpu"):
                    raw_scores = raw_scores.cpu()
                scores = normalized_scores(raw_scores, self.manifest.labels)
                ambiguous = is_ambiguous_scores(scores, self.manifest)
                verifier = None
                if ambiguous:
                    verifier_was_needed = True
                    if self.verifier is not None:

                        def verifier(top, candidates, crop=crop):
                            return _call_crop_verifier(
                                self.verifier, crop, top, candidates
                            )

                decision = classify_policy(
                    scores,
                    _policy_box(box),
                    (image_width, image_height),
                    self.manifest,
                    verifier=verifier,
                ).to_json()
                decisions.append(decision)
            errors = []
            if verifier_was_needed and self.verifier_error:
                errors.append(_stage_error("verifier", self.verifier_error))
            return decisions, errors
        except Exception as error:
            message = str(error) or error.__class__.__name__
            return (
                [_unavailable_label(message) for _ in boxes],
                [_stage_error("classifier", message)],
            )


def create_pipeline_engine(
    manifest,
    resolved_models,
    *,
    cv2,
    np,
    detector_factory,
    classifier_factory,
    verifier_factory=None,
):
    """Construct each configured model at most once for one worker lifetime."""

    detector = detector_factory(resolved_models.detector_path)
    classifier = None
    classifier_error = resolved_models.classifier_error
    if resolved_models.classifier_path is not None:
        try:
            classifier = classifier_factory(resolved_models.classifier_path)
        except Exception as error:
            classifier_error = str(error) or error.__class__.__name__

    verifier = None
    verifier_error = None
    # This branch deliberately precedes any verifier factory call. A `none`
    # manifest must not import, resolve, or construct verifier dependencies.
    if manifest.verifier["kind"] != "none":
        verifier_error = resolved_models.verifier_error
        if resolved_models.verifier_path is not None:
            try:
                if verifier_factory is None:
                    raise RuntimeError("verifier factory unavailable")
                verifier = verifier_factory(resolved_models.verifier_path)
            except Exception as error:
                verifier_error = str(error) or error.__class__.__name__
    return BreadInferenceEngine(
        manifest,
        cv2,
        np,
        detector,
        classifier,
        verifier,
        classifier_error=classifier_error,
        verifier_error=verifier_error,
    )


def load_runtime_engine(manifest_path, cv2, np, yolo_factory):
    manifest_path = Path(manifest_path)
    manifest = load_pipeline_manifest(manifest_path)
    resolved_models = resolve_model_paths(manifest_path, manifest)
    return create_pipeline_engine(
        manifest,
        resolved_models,
        cv2=cv2,
        np=np,
        detector_factory=yolo_factory,
        classifier_factory=yolo_factory,
    )


def ready_message(engine):
    manifest = engine.manifest
    return {
        "version": PROTOCOL_VERSION,
        "type": "ready",
        "detectorName": "bread-yolo-boxes",
        "capabilities": {
            "detect": True,
            "classify": True,
            "autoLabel": True,
            "verifier": manifest.verifier["kind"] != "none",
        },
    }


def _result_message(engine, request_id, result, payload):
    manifest = getattr(engine, "manifest", None)
    if manifest is None:
        image = result.get("image") or {
            "width": result["width"],
            "height": result["height"],
            "sha256": hashlib.sha256(payload).hexdigest(),
        }
        pipeline_version = "bread-pipeline-v1"
        policy_version = "bread-label-policy-v2"
        model_hashes = {"detector": None, "classifier": None, "verifier": None}
    else:
        image = result["image"]
        pipeline_version = manifest.pipeline_version
        policy_version = manifest.policy_version
        model_hashes = {
            "detector": manifest.detector["sha256"],
            "classifier": manifest.classifier["sha256"],
            "verifier": manifest.verifier["sha256"],
        }
    return {
        "version": PROTOCOL_VERSION,
        "type": "result",
        "requestId": request_id,
        "pipelineVersion": pipeline_version,
        "policyVersion": policy_version,
        "detectorName": "bread-yolo-boxes",
        "modelHashes": model_hashes,
        "image": image,
        "boxes": result["boxes"],
        "stageErrors": result.get("stageErrors", []),
    }


def _validate_request_header(header):
    version = header.get("version")
    if type(version) is not int or version != PROTOCOL_VERSION:
        raise ValueError("unsupported protocol version")
    request_type = header.get("type")
    if type(request_type) is not str or request_type not in {
        "detect",
        "classify",
        "shutdown",
    }:
        raise ValueError("unsupported request type")
    request_id = header.get("requestId")
    if not isinstance(request_id, str) or not request_id:
        raise ValueError("request ID must be a non-empty string")
    if request_type != "classify":
        return
    boxes = header.get("boxes")
    if not isinstance(boxes, list):
        raise ValueError("classify boxes must be an array")
    if len(boxes) > 100:
        raise ValueError("classify accepts at most 100 boxes")
    for item in boxes:
        if not isinstance(item, dict):
            raise ValueError("classify box must be an object with a valid ID")
        identifier = item.get("id")
        if not isinstance(identifier, str) or not identifier:
            raise ValueError("classify box ID must be a non-empty string")


def serve(stdin, stdout, engine):
    while True:
        request = read_request(stdin)
        if request is None:
            return 0
        header, payload = request
        _validate_request_header(header)
        request_id = header["requestId"]
        request_type = header.get("type")
        if request_type == "shutdown":
            return 0
        try:
            if request_type == "detect":
                result = engine.detect_bytes(payload, header.get("maxProposals"))
            elif request_type == "classify":
                result = engine.classify_bytes(payload, header.get("boxes", []))
            else:
                raise ValueError("unsupported request type")
            write_json_frame(stdout, _result_message(engine, request_id, result, payload))
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


def _pipeline_detection_boxes(result, *, image_width, image_height):
    if result.boxes is None:
        return [], []
    try:
        rows = _tensor_list(result.boxes.xyxy)
        confidences = _tensor_list(result.boxes.conf)
    except (TypeError, ValueError, OverflowError, AttributeError) as error:
        return [], [_stage_error("detector", f"invalid detector output: {error}")]
    boxes = []
    malformed = len(rows) != len(confidences)
    for index, row in enumerate(rows):
        if (
            not isinstance(row, (list, tuple))
            or len(row) != 4
            or not all(_is_finite_builtin_number(value) for value in row)
        ):
            malformed = True
            continue
        if index >= len(confidences):
            malformed = True
            continue
        raw_confidence = confidences[index]
        if not _is_probability(raw_confidence):
            malformed = True
            continue
        values = tuple(float(value) for value in row)
        confidence = float(raw_confidence)
        clamped, changed = _clamp_xyxy(
            values, image_width=image_width, image_height=image_height
        )
        if clamped[2] <= clamped[0] or clamped[3] <= clamped[1]:
            continue
        boxes.append(
            {
                "id": f"proposal-{index + 1}",
                "xyxy": clamped,
                "confidence": round(confidence, 4),
                "edge_clipped": changed,
            }
        )
    errors = (
        [_stage_error("detector", "malformed detector boxes were omitted")]
        if malformed
        else []
    )
    return boxes, errors


def _tensor_list(value):
    if hasattr(value, "cpu"):
        value = value.cpu()
    if hasattr(value, "tolist"):
        value = value.tolist()
    elif hasattr(value, "numpy"):
        value = value.numpy().tolist()
    if not isinstance(value, (list, tuple)):
        raise TypeError("detector tensor must contain a sequence")
    return value


def _is_finite_builtin_number(value):
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(float(value))
    except (OverflowError, TypeError, ValueError):
        return False


def _is_probability(value):
    if not _is_finite_builtin_number(value):
        return False
    number = float(value)
    return 0.0 <= number <= 1.0


def _supplied_pipeline_box(item, *, image_width, image_height):
    try:
        values = (
            _finite_number(item["x"]),
            _finite_number(item["y"]),
            _finite_number(item["x"]) + _finite_number(item["width"]),
            _finite_number(item["y"]) + _finite_number(item["height"]),
        )
    except (KeyError, TypeError, ValueError, OverflowError):
        return None
    clamped, changed = _clamp_xyxy(
        values, image_width=image_width, image_height=image_height
    )
    if clamped[2] <= clamped[0] or clamped[3] <= clamped[1]:
        return None
    return {
        "id": item.get("id"),
        "xyxy": clamped,
        "confidence": _optional_confidence(item.get("confidence")),
        "edge_clipped": changed,
    }


def _optional_confidence(value):
    return float(value) if _is_probability(value) else None


def _finite_number(value):
    if type(value) not in (int, float):
        raise ValueError("coordinate must be numeric")
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("coordinate must be finite")
    return number


def _clamp_xyxy(values, *, image_width, image_height):
    x1, y1, x2, y2 = values
    clamped = (
        max(0.0, min(x1, float(image_width))),
        max(0.0, min(y1, float(image_height))),
        max(0.0, min(x2, float(image_width))),
        max(0.0, min(y2, float(image_height))),
    )
    return clamped, clamped != tuple(values)


def _crop_box(image, xyxy):
    x1, y1, x2, y2 = xyxy
    return image[
        int(math.floor(y1)) : int(math.ceil(y2)),
        int(math.floor(x1)) : int(math.ceil(x2)),
    ]


def _call_crop_verifier(verifier, crop, top_label_id, candidates):
    target = getattr(verifier, "verify", None)
    if target is None:
        target = getattr(verifier, "predict", verifier)
    if not callable(target):
        raise TypeError("verifier must be callable")
    try:
        signature = inspect.signature(target)
    except (TypeError, ValueError):
        return target(crop, top_label_id, candidates)
    for arguments in (
        (crop, top_label_id, candidates),
        (crop, top_label_id),
        (crop,),
    ):
        try:
            signature.bind(*arguments)
        except TypeError:
            continue
        return target(*arguments)
    raise TypeError("verifier has an unsupported call signature")


def _policy_box(box):
    x1, y1, x2, y2 = box["xyxy"]
    return {"x": x1, "y": y1, "width": x2 - x1, "height": y2 - y1}


def _json_pipeline_box(box, label):
    x1, y1, x2, y2 = box["xyxy"]
    return {
        "id": box.get("id"),
        "x": round(float(x1), 2),
        "y": round(float(y1), 2),
        "width": round(float(x2 - x1), 2),
        "height": round(float(y2 - y1), 2),
        "confidence": box.get("confidence"),
        "label": label,
    }


def _unavailable_label(message):
    return {
        "state": "unavailable",
        "labelId": None,
        "suggestedLabelId": None,
        "candidates": [],
        "reviewReasons": ["classifier_unavailable"],
        "embeddingUsed": False,
        "message": message,
    }


def _stage_error(stage, message):
    return {"stage": stage, "message": message}


def _add_review_reason(label, reason):
    result = dict(label)
    reasons = list(result.get("reviewReasons", []))
    if reason not in reasons:
        reasons.append(reason)
    result["reviewReasons"] = reasons
    return result


def _apply_duplicate_review(boxes, threshold):
    overlaps = set()
    internal = []
    for item in boxes:
        internal.append(
            {
                "xyxy": (
                    item["x"],
                    item["y"],
                    item["x"] + item["width"],
                    item["y"] + item["height"],
                )
            }
        )
    for left in range(len(internal)):
        for right in range(left + 1, len(internal)):
            if _iou(internal[left], internal[right]) >= threshold:
                overlaps.update((left, right))
    for index in overlaps:
        boxes[index]["label"] = _add_review_reason(
            boxes[index]["label"], "possible_duplicate"
        )


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


def select_runtime(args, cv2, np, yolo_factory):
    if args.pipeline_manifest:
        engine = load_runtime_engine(
            Path(args.pipeline_manifest), cv2, np, yolo_factory
        )
        return engine, ready_message(engine)
    if args.detector_model:
        detector_path = Path(args.detector_model)
        if not detector_path.is_file():
            raise FileNotFoundError(f"detector model does not exist: {detector_path}")
        engine = BreadBoxEngine(args, cv2, np, yolo_factory)
        return engine, {
            "version": PROTOCOL_VERSION,
            "type": "ready",
            "detectorName": "bread-yolo-boxes",
            "model": detector_path.name,
        }
    raise ValueError("--pipeline-manifest or --detector-model is required")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Persistent CPU bread detection and auto-label pipeline."
    )
    parser.add_argument("--pipeline-manifest")
    parser.add_argument("--detector-model")
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--det-conf", type=float, default=0.40)
    parser.add_argument("--iou", type=float, default=0.55)
    parser.add_argument("--max-results", type=int, default=50)
    parser.add_argument("--min-box-size", type=int, default=45)
    parser.add_argument("--max-area-ratio", type=float, default=0.38)
    args = parser.parse_args()

    if not args.pipeline_manifest and not args.detector_model:
        parser.error("--pipeline-manifest or --detector-model is required")

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
            engine, ready = select_runtime(args, cv2, np, YOLO)
    except Exception as error:
        print(f"Bread worker initialization failed: {error}", file=sys.stderr)
        return 5

    write_json_frame(sys.stdout.buffer, ready)
    return serve(sys.stdin.buffer, sys.stdout.buffer, engine)


if __name__ == "__main__":
    raise SystemExit(main())
