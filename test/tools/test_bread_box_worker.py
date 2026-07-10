import importlib.util
import io
import json
import struct
import types
import unittest
from pathlib import Path

import cv2
import numpy as np


MODULE_PATH = Path(__file__).resolve().parents[2] / "tools" / "detectors" / "bread_box_worker.py"
SPEC = importlib.util.spec_from_file_location("bread_box_worker", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
worker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(worker)


def request_frame(
    request_id: str,
    payload: bytes,
    *,
    request_type="detect",
    max_proposals=None,
) -> bytes:
    fields = {
        "version": 1,
        "type": request_type,
        "requestId": request_id,
        "fileName": "한글 image.png",
    }
    if max_proposals is not None:
        fields["maxProposals"] = max_proposals
    header = json.dumps(
        fields,
        ensure_ascii=False,
    ).encode("utf-8")
    return (
        struct.pack(">I", len(header))
        + header
        + struct.pack(">Q", len(payload))
        + payload
    )


def response_frames(data: bytes):
    stream = io.BytesIO(data)
    decoded = []
    while stream.tell() < len(data):
        length = struct.unpack(">I", stream.read(4))[0]
        decoded.append(json.loads(stream.read(length).decode("utf-8")))
    return decoded


def box(x1, y1, x2, y2, confidence=0.9):
    return {"xyxy": (x1, y1, x2, y2), "confidence": confidence}


def png_bytes():
    success, encoded = cv2.imencode(".png", np.zeros((2, 2, 3), dtype=np.uint8))
    assert success
    return encoded.tobytes()


class EmptyBoxesResult:
    boxes = None


class FakeDetector:
    def __init__(self):
        self.calls = []

    def predict(self, image, **kwargs):
        self.calls.append((image, kwargs))
        return [EmptyBoxesResult()]


def engine_args():
    return types.SimpleNamespace(
        detector_model="bread.pt",
        imgsz=640,
        det_conf=0.40,
        iou=0.55,
        max_results=50,
        min_box_size=45,
        max_area_ratio=0.38,
    )


class FakeEngine:
    def __init__(self):
        self.calls = []

    def detect_bytes(self, payload, max_proposals=None):
        self.calls.append((payload, max_proposals))
        return {"width": 100, "height": 80, "boxes": []}


class WorkerProtocolTest(unittest.TestCase):
    def test_two_requests_reuse_one_engine(self):
        engine = FakeEngine()
        stdin = io.BytesIO(request_frame("1", b"first") + request_frame("2", b"second"))
        stdout = io.BytesIO()

        worker.serve(stdin, stdout, engine)

        self.assertEqual(engine.calls, [(b"first", None), (b"second", None)])
        self.assertEqual(
            [item["requestId"] for item in response_frames(stdout.getvalue())],
            ["1", "2"],
        )

    def test_shutdown_exits_without_detection(self):
        engine = FakeEngine()
        stdin = io.BytesIO(request_frame("stop", b"", request_type="shutdown"))
        stdout = io.BytesIO()
        self.assertEqual(worker.serve(stdin, stdout, engine), 0)
        self.assertEqual(engine.calls, [])

    def test_truncated_payload_raises_eof_error(self):
        header = json.dumps(
            {"version": 1, "type": "detect", "requestId": "short"}
        ).encode("utf-8")
        frame = struct.pack(">I", len(header)) + header + struct.pack(">Q", 5) + b"ab"

        with self.assertRaisesRegex(EOFError, "expected 5 bytes"):
            worker.read_request(io.BytesIO(frame))

    def test_oversized_header_is_rejected(self):
        frame = struct.pack(">I", worker.MAX_HEADER_BYTES + 1)

        with self.assertRaisesRegex(ValueError, "64 KiB"):
            worker.read_request(io.BytesIO(frame))

    def test_corrupt_image_returns_decode_failed_and_keeps_worker_alive(self):
        detector = FakeDetector()
        engine = worker.BreadBoxEngine(
            engine_args(), cv2, np, lambda _model_path: detector
        )
        stdin = io.BytesIO(
            request_frame("bad", b"not an image")
            + request_frame("good", png_bytes())
        )
        stdout = io.BytesIO()

        worker.serve(stdin, stdout, engine)

        responses = response_frames(stdout.getvalue())
        self.assertEqual(responses[0]["code"], "decode_failed")
        self.assertEqual(responses[1]["type"], "result")

    def test_empty_payload_returns_decode_failed_and_keeps_worker_alive(self):
        detector = FakeDetector()
        engine = worker.BreadBoxEngine(
            engine_args(), cv2, np, lambda _model_path: detector
        )
        stdin = io.BytesIO(
            request_frame("empty", b"") + request_frame("good", png_bytes())
        )
        stdout = io.BytesIO()

        worker.serve(stdin, stdout, engine)

        responses = response_frames(stdout.getvalue())
        self.assertEqual(responses[0]["code"], "decode_failed")
        self.assertEqual(responses[1]["type"], "result")
        self.assertEqual(len(detector.calls), 1)

    def test_max_proposals_is_passed_per_request(self):
        engine = FakeEngine()
        stdin = io.BytesIO(request_frame("limited", b"image", max_proposals=7))
        stdout = io.BytesIO()

        worker.serve(stdin, stdout, engine)

        self.assertEqual(engine.calls, [(b"image", 7)])

    def test_model_factory_is_called_once_for_two_requests(self):
        factory_calls = []
        detector = FakeDetector()

        def counting_factory(model_path):
            factory_calls.append(model_path)
            return detector

        engine = worker.BreadBoxEngine(engine_args(), cv2, np, counting_factory)
        payload = png_bytes()
        stdin = io.BytesIO(
            request_frame("1", payload) + request_frame("2", payload)
        )
        stdout = io.BytesIO()

        worker.serve(stdin, stdout, engine)

        self.assertEqual(factory_calls, ["bread.pt"])
        self.assertEqual(len(response_frames(stdout.getvalue())), 2)


class BreadBoxWorkerPostprocessTest(unittest.TestCase):
    def test_remove_aggregate_boxes_drops_box_covering_multiple_smaller_boxes(self):
        aggregate = box(100, 100, 500, 500, confidence=0.52)
        boxes = [
            aggregate,
            box(120, 130, 260, 280, confidence=0.91),
            box(290, 140, 470, 300, confidence=0.88),
            box(180, 310, 430, 470, confidence=0.83),
        ]

        filtered = worker._remove_aggregate_boxes(boxes)

        self.assertNotIn(aggregate, filtered)
        self.assertEqual(len(filtered), 3)

    def test_remove_aggregate_boxes_keeps_large_single_object_box(self):
        long_bread = box(100, 100, 500, 500, confidence=0.52)
        boxes = [
            long_bread,
            box(440, 430, 560, 560, confidence=0.88),
        ]

        filtered = worker._remove_aggregate_boxes(boxes)

        self.assertIn(long_bread, filtered)
        self.assertEqual(len(filtered), 2)

    def test_remove_aggregate_boxes_drops_low_confidence_box_with_one_large_overlap(self):
        aggregate = box(100, 100, 500, 500, confidence=0.52)
        boxes = [
            aggregate,
            box(100, 280, 460, 500, confidence=0.89),
        ]

        filtered = worker._remove_aggregate_boxes(boxes)

        self.assertNotIn(aggregate, filtered)
        self.assertEqual(len(filtered), 1)

    def test_remove_aggregate_boxes_keeps_high_confidence_specific_box(self):
        high_confidence = box(100, 100, 500, 500, confidence=0.82)
        boxes = [
            high_confidence,
            box(120, 130, 260, 280, confidence=0.91),
            box(290, 140, 470, 300, confidence=0.88),
            box(180, 310, 430, 470, confidence=0.83),
        ]

        filtered = worker._remove_aggregate_boxes(boxes)

        self.assertIn(high_confidence, filtered)


if __name__ == "__main__":
    unittest.main()
