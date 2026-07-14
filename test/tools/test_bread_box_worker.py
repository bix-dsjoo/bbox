import importlib.util
import hashlib
import io
import json
import struct
import sys
import types
import unittest
from pathlib import Path

import cv2
import numpy as np


MODULE_PATH = (
    Path(__file__).resolve().parents[2] / "tools" / "detectors" / "bread_box_worker.py"
)
PROJECT_ROOT = str(Path(__file__).resolve().parents[2])
if PROJECT_ROOT not in sys.path:
    sys.path.insert(0, PROJECT_ROOT)
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


def pipeline_png_bytes(width=100, height=80):
    success, encoded = cv2.imencode(
        ".png", np.zeros((height, width, 3), dtype=np.uint8)
    )
    assert success
    return encoded.tobytes()


class FakeTensor:
    def __init__(self, values):
        self.values = values

    def cpu(self):
        return self

    def numpy(self):
        return np.asarray(self.values, dtype=float)

    def tolist(self):
        return list(self.values)


class DetectionBoxes:
    def __init__(self, rows, confidences):
        self.xyxy = FakeTensor(rows)
        self.conf = FakeTensor(confidences)


class DetectionResult:
    def __init__(self, rows):
        self.boxes = DetectionBoxes([row[:4] for row in rows], [row[4] for row in rows])


class PipelineDetector:
    def __init__(self, rows):
        self.rows = rows
        self.calls = []

    def predict(self, image, **kwargs):
        self.calls.append((image, kwargs))
        return [DetectionResult(self.rows)]


class ClassifierResult:
    def __init__(self, scores):
        self.probs = types.SimpleNamespace(data=FakeTensor(scores))


class BatchClassifier:
    def __init__(self, scores):
        self.scores = scores
        self.calls = []

    def predict(self, crops, **kwargs):
        self.calls.append((crops, kwargs))
        return [ClassifierResult(scores) for scores in self.scores]


class FailingClassifier:
    def predict(self, crops, **kwargs):
        raise RuntimeError("classifier unavailable")


class RecordingVerifier:
    def __init__(self):
        self.crops = []

    def verify(self, crop, top_label_id, candidates):
        self.crops.append(crop)
        return {"labelId": top_label_id, "score": 0.99, "margin": 0.9}


class CropOnlyVerifier:
    def __init__(self):
        self.crops = []

    def verify(self, crop):
        self.crops.append(crop)
        return {"labelId": 1, "score": 0.99, "margin": 0.9}


def pipeline_manifest(*, verifier_kind="none", duplicate_iou=0.95):
    return types.SimpleNamespace(
        detector={"imgsz": 640, "confidence": 0.4, "iou": 0.55},
        classifier={
            "imgsz": 224,
            "acceptConfidence": 0.8,
            "acceptMargin": 0.2,
            "conservativeClasses": [],
        },
        verifier={
            "kind": verifier_kind,
            "scoreThreshold": None if verifier_kind == "none" else 0.9,
            "marginThreshold": None if verifier_kind == "none" else 0.2,
        },
        quality={
            "minBoxSize": 1,
            "maxAreaRatio": 1.0,
            "edgeMarginPx": 0,
            "duplicateIou": duplicate_iou,
        },
        labels=(
            types.SimpleNamespace(id=1, name="one"),
            types.SimpleNamespace(id=2, name="two"),
            types.SimpleNamespace(id=3, name="three"),
        ),
    )


def pipeline_engine(detector, classifier, verifier=None, *, manifest=None):
    return worker.BreadInferenceEngine(
        manifest
        or pipeline_manifest(
            verifier_kind="embedding" if verifier is not None else "none"
        ),
        cv2,
        np,
        detector,
        classifier,
        verifier,
    )


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
            request_frame("bad", b"not an image") + request_frame("good", png_bytes())
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
        stdin = io.BytesIO(request_frame("1", payload) + request_frame("2", payload))
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

    def test_remove_aggregate_boxes_drops_low_confidence_box_with_one_large_overlap(
        self,
    ):
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


class BreadInferenceEngineTest(unittest.TestCase):
    def test_classifier_receives_one_crop_batch_and_verifier_only_ambiguous_crop(self):
        detector = PipelineDetector([(2, 3, 30, 32, 0.9), (40, 5, 75, 45, 0.8)])
        classifier = BatchClassifier([(0.95, 0.03, 0.02), (0.55, 0.4, 0.05)])
        verifier = RecordingVerifier()
        engine = pipeline_engine(detector, classifier, verifier)

        result = engine.detect_bytes(pipeline_png_bytes())

        self.assertEqual(len(classifier.calls), 1)
        crops, kwargs = classifier.calls[0]
        self.assertEqual(len(crops), 2)
        self.assertEqual(kwargs["batch"], 2)
        self.assertEqual(len(verifier.crops), 1)
        self.assertEqual(
            [item["label"]["state"] for item in result["boxes"]],
            ["accepted", "accepted"],
        )

    def test_none_verifier_manifest_skips_verifier_construction(self):
        calls = []
        manifest = pipeline_manifest(verifier_kind="none")
        resolved = types.SimpleNamespace(
            detector_path=Path("detector.pt"),
            classifier_path=Path("classifier.pt"),
            classifier_error=None,
            verifier_path=None,
            verifier_error=None,
        )

        engine = worker.create_pipeline_engine(
            manifest,
            resolved,
            cv2=cv2,
            np=np,
            detector_factory=lambda _path: PipelineDetector(
                [(2, 3, 30, 32, 0.9), (40, 5, 75, 45, 0.8)]
            ),
            classifier_factory=lambda _path: BatchClassifier(
                [(0.95, 0.03, 0.02), (0.55, 0.4, 0.05)]
            ),
            verifier_factory=lambda path, specification: calls.append(
                (path, specification)
            ),
        )
        result = engine.detect_bytes(pipeline_png_bytes())

        self.assertEqual(calls, [])
        self.assertIsNone(engine.verifier)
        self.assertEqual(result["boxes"][1]["label"]["state"], "review")

    def test_crop_only_verifier_receives_only_ambiguous_crop(self):
        verifier = CropOnlyVerifier()
        engine = pipeline_engine(
            PipelineDetector([(2, 3, 30, 32, 0.9), (40, 5, 75, 45, 0.8)]),
            BatchClassifier([(0.95, 0.03, 0.02), (0.55, 0.4, 0.05)]),
            verifier,
        )

        result = engine.detect_bytes(pipeline_png_bytes())

        self.assertEqual(len(verifier.crops), 1)
        self.assertEqual(result["boxes"][1]["label"]["state"], "accepted")

    def test_classifier_batch_is_capped_at_sixteen(self):
        rows = [(index * 2, 5, index * 2 + 1, 10, 0.9) for index in range(17)]
        classifier = BatchClassifier([(0.95, 0.03, 0.02)] * 17)
        engine = pipeline_engine(PipelineDetector(rows), classifier)

        engine.detect_bytes(pipeline_png_bytes(width=100, height=20))

        self.assertEqual(classifier.calls[0][1]["batch"], 16)

    def test_manifest_factory_loads_detector_and_classifier_once(self):
        detector_calls = []
        classifier_calls = []
        manifest = pipeline_manifest()
        resolved = types.SimpleNamespace(
            detector_path=Path("detector.pt"),
            classifier_path=Path("classifier.pt"),
            classifier_error=None,
            verifier_path=None,
            verifier_error=None,
        )
        detector = PipelineDetector([])
        classifier = BatchClassifier([])
        engine = worker.create_pipeline_engine(
            manifest,
            resolved,
            cv2=cv2,
            np=np,
            detector_factory=lambda path: detector_calls.append(path) or detector,
            classifier_factory=lambda path: classifier_calls.append(path) or classifier,
        )

        engine.detect_bytes(pipeline_png_bytes())
        engine.detect_bytes(pipeline_png_bytes())

        self.assertEqual(detector_calls, [Path("detector.pt")])
        self.assertEqual(classifier_calls, [Path("classifier.pt")])

    def test_classifier_failure_preserves_gray_boxes_and_stage_error(self):
        engine = pipeline_engine(
            PipelineDetector([(2, 3, 30, 32, 0.9), (40, 5, 75, 45, 0.8)]),
            FailingClassifier(),
        )

        result = engine.detect_bytes(pipeline_png_bytes())

        self.assertEqual(len(result["boxes"]), 2)
        self.assertTrue(
            all(item["label"]["state"] == "unavailable" for item in result["boxes"])
        )
        self.assertEqual(result["stageErrors"][0]["stage"], "classifier")

    def test_missing_classifier_preserves_gray_boxes(self):
        engine = worker.BreadInferenceEngine(
            pipeline_manifest(),
            cv2,
            np,
            PipelineDetector([(2, 3, 30, 32, 0.9)]),
            None,
            None,
            classifier_error="classifier weights missing",
        )

        result = engine.detect_bytes(pipeline_png_bytes())

        self.assertEqual(result["boxes"][0]["label"]["state"], "unavailable")
        self.assertEqual(result["stageErrors"][0]["stage"], "classifier")

    def test_classify_request_uses_supplied_original_pixel_boxes_and_ids(self):
        engine = pipeline_engine(
            PipelineDetector([]), BatchClassifier([(0.95, 0.03, 0.02)])
        )

        result = engine.classify_bytes(
            pipeline_png_bytes(),
            [{"id": "manual-1", "x": 2, "y": 3, "width": 10, "height": 11}],
        )

        self.assertEqual(result["boxes"][0]["id"], "manual-1")
        self.assertEqual(result["boxes"][0]["x"], 2)
        self.assertEqual(engine.detector.calls, [])

    def test_finite_boundary_overrun_is_clamped_and_marked_for_review(self):
        engine = pipeline_engine(
            PipelineDetector([(-0.2, 2, 20, 20, 0.9)]),
            BatchClassifier([(0.95, 0.03, 0.02)]),
        )

        result = engine.detect_bytes(pipeline_png_bytes())

        self.assertEqual(result["boxes"][0]["x"], 0)
        self.assertIn("edge_clipped", result["boxes"][0]["label"]["reviewReasons"])

    def test_nonfinite_and_nonpositive_boxes_are_discarded(self):
        engine = pipeline_engine(
            PipelineDetector([(float("nan"), 2, 20, 20, 0.9), (5, 5, 5, 10, 0.8)]),
            BatchClassifier([]),
        )

        result = engine.detect_bytes(pipeline_png_bytes())

        self.assertEqual(result["boxes"], [])

    def test_request_bytes_are_hashed(self):
        payload = pipeline_png_bytes()
        engine = pipeline_engine(PipelineDetector([]), BatchClassifier([]))

        result = engine.detect_bytes(payload)

        self.assertEqual(result["image"]["sha256"], hashlib.sha256(payload).hexdigest())

    def test_supplied_box_clamping_preserves_id_and_adds_edge_review(self):
        engine = pipeline_engine(
            PipelineDetector([]), BatchClassifier([(0.95, 0.03, 0.02)])
        )

        result = engine.classify_bytes(
            pipeline_png_bytes(),
            [{"id": "manual", "x": 90, "y": 70, "width": 20, "height": 20}],
        )

        self.assertEqual(result["boxes"][0]["id"], "manual")
        self.assertEqual(result["boxes"][0]["width"], 10)
        self.assertIn("edge_clipped", result["boxes"][0]["label"]["reviewReasons"])

    def test_duplicate_reason_is_applied_to_survivors_after_nms(self):
        engine = pipeline_engine(
            PipelineDetector([(5, 5, 35, 35, 0.9), (10, 10, 40, 40, 0.8)]),
            BatchClassifier([(0.95, 0.03, 0.02), (0.95, 0.03, 0.02)]),
            manifest=pipeline_manifest(duplicate_iou=0.5),
        )

        result = engine.detect_bytes(pipeline_png_bytes())

        self.assertEqual(len(result["boxes"]), 2)
        self.assertTrue(
            all(
                "possible_duplicate" in item["label"]["reviewReasons"]
                for item in result["boxes"]
            )
        )


if __name__ == "__main__":
    unittest.main()
