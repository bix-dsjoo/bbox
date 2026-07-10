# Auto Box Worker Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Load the bread bounding-box model once at app startup, stream encoded image bytes from Dart to a persistent Python worker, recover from one worker failure without destructive UI changes, and remove FastSAM and automatic classification from the product.

**Architecture:** A long-lived `AutoBoxService` owns a `BreadWorkerClient`; the client owns the Python process and uses a length-prefixed binary stdin/stdout protocol. `BboxApp` starts warm-up without blocking first paint, `AppController` applies only validated bbox proposals, and the Python worker decodes in-memory JPEG/PNG bytes without receiving a source path.

**Tech Stack:** Flutter/Dart desktop, `dart:io`, `ChangeNotifier`, Python 3.12, OpenCV/NumPy, Ultralytics YOLO CPU, `flutter_test`, Python `unittest`, PowerShell packaging, Windows CMake, Inno Setup.

## Global Constraints

- Automatic boxes return bbox coordinates and detector confidence only.
- Every automatic result is `BoxStatus.proposal` with `labelId: null`.
- Start model warm-up immediately after app startup without blocking the first frame.
- Keep one worker for the whole app lifetime, including project-home navigation and project switches.
- Send encoded image bytes; never send the original image path to Python.
- Request framing uses unsigned big-endian integers, protocol version `1`, a 64 KiB request-header limit, a 512 MiB image-payload limit, and a 1 MiB response limit.
- Process one image at a time.
- On transport, protocol, or inference failure, restart once and retry once. Do not retry file-read or decode errors.
- On final failure, preserve existing boxes, selection, image status, and Undo history.
- On success, replace all visible boxes and preserve existing Undo and autosave semantics.
- Remove FastSAM, the one-shot bread sidecar, classifier loading, CLIP verification, and silent model fallback.
- Required release assets are `runtime/python/python.exe`, `tools/detectors/bread_box_worker.py`, and `models/bread_yolov8n_1class_tray_v0_2.pt`.
- Release and installer outputs must not contain `FastSAM-s.pt`, `fastsam_detector.py`, `bread_vision_detector.py`, or `bread_classifier_yolov8n_cls_best.pt`.
- Keep COCO export and original-image-coordinate semantics unchanged.
- This workspace has no `.git` directory; replace commit steps with task checkpoints and do not initialize a repository.

## File Structure

- Create `tools/detectors/bread_box_worker.py`: framed binary worker, model initialization, in-memory decode, bbox inference, and shutdown.
- Create `test/tools/test_bread_box_worker.py`: Python protocol, decode, postprocess, and one-model-load tests.
- Create `lib/detector/worker_protocol.dart`: pure framing constants, exact byte reader, request writer, and response parsing.
- Create `test/detector/worker_protocol_test.dart`: fragmented-stream, limits, UTF-8, and framing tests.
- Create `lib/detector/bread_worker_client.dart`: Python process lifecycle, ready handshake, stderr ring buffer, detect, and shutdown.
- Create `test/detector/bread_worker_client_test.dart`: fake-process lifecycle and protocol tests.
- Create `lib/detector/auto_box_service.dart`: warm-up state machine, streamed file opening, single-flight detection, restart, and retry policy.
- Create `test/detector/auto_box_service_test.dart`: warm-up deduplication, retry classification, state, and shutdown tests.
- Create `test/support/fake_auto_box_runtime.dart`: shared controllable runtime for controller and widget tests without starting Python.
- Modify `lib/detector/detector.dart`: retain detector result/options/test interface and simple detectors; remove sidecar implementations and label mapping.
- Modify `lib/ui/app_controller.dart`: own or receive `AutoBoxService`, expose service state, use it by default, reject stale results, and preserve project mutation rules.
- Modify `lib/ui/bbox_app.dart`: start warm-up after initialization and shut down app-owned detector resources.
- Modify `lib/ui/workbench_copy.dart`: replace per-click model-loading copy with preparation, restart, retry, and failure copy.
- Modify `lib/ui/workbench/center_toolbar.dart`: render state-specific automatic-box action.
- Modify `lib/ui/workbench/workbench_screen.dart`: gate the keyboard shortcut with the same controller capability.
- Modify `test/ui/app_controller_auto_box_test.dart`: production-service integration and stale-result tests.
- Modify `test/ui/workbench/center_toolbar_test.dart`: preparation, running, restarting, failed, and retry button tests.
- Modify `test/widget_test.dart`: first paint does not wait for warm-up and startup calls warm-up once.
- Modify `test/ui/project_home_widget_test.dart`: inject the shared fake runtime so project-home widget tests never start Python.
- Delete `tools/detectors/fastsam_detector.py`, `tools/detectors/bread_vision_detector.py`, `test/tools/test_bread_vision_detector.py`, and workspace `FastSAM-s.pt`.
- Modify `test/detector/dummy_detector_test.dart`: remove legacy sidecar tests and retain tests for simple detector contracts/path selection where still relevant.
- Modify `windows/CMakeLists.txt`, `tools/packaging/build_windows_installer.ps1`, `installer/bbox_labeler.iss`, and `test/packaging/installer_script_test.dart`: copy only required detector assets and remove stale forbidden assets.
- Modify `README.md`, `docs/release-checklist.md`, `models/README.md`, and `docs/project-structure.md`: document the coordinate-only persistent worker and mandatory release assets.

---

### Task 1: Python Framed Bread Box Worker

**Files:**
- Create: `C:\workspace\bbox\tools\detectors\bread_box_worker.py`
- Create: `C:\workspace\bbox\test\tools\test_bread_box_worker.py`
- Reference: `C:\workspace\bbox\tools\detectors\bread_vision_detector.py`
- Reference: `C:\workspace\bbox\test\tools\test_bread_vision_detector.py`

**Interfaces:**
- Consumes stdin request frame: `uint32 headerLength`, UTF-8 JSON header, `uint64 payloadLength`, encoded image bytes.
- Produces stdout JSON frame: `uint32 jsonLength`, UTF-8 JSON with type `ready`, `result`, or `error`.
- Produces `BreadBoxEngine.detect_bytes(payload: bytes, max_proposals: int | None) -> dict`.
- Produces `serve(stdin: BinaryIO, stdout: BinaryIO, engine: BreadBoxEngine) -> int`.

- [ ] **Step 1: Write failing protocol and model-lifetime tests**

Create `test/tools/test_bread_box_worker.py` with helpers that frame a request without touching disk:

```python
import importlib.util
import io
import json
import struct
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[2] / "tools" / "detectors" / "bread_box_worker.py"
SPEC = importlib.util.spec_from_file_location("bread_box_worker", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
worker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(worker)


def request_frame(request_id: str, payload: bytes, *, request_type="detect") -> bytes:
    header = json.dumps({
        "version": 1,
        "type": request_type,
        "requestId": request_id,
        "fileName": "한글 image.png",
    }, ensure_ascii=False).encode("utf-8")
    return struct.pack(">I", len(header)) + header + struct.pack(">Q", len(payload)) + payload


def response_frames(data: bytes):
    stream = io.BytesIO(data)
    decoded = []
    while stream.tell() < len(data):
        length = struct.unpack(">I", stream.read(4))[0]
        decoded.append(json.loads(stream.read(length).decode("utf-8")))
    return decoded


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
        self.assertEqual([item["requestId"] for item in response_frames(stdout.getvalue())], ["1", "2"])

    def test_shutdown_exits_without_detection(self):
        engine = FakeEngine()
        stdin = io.BytesIO(request_frame("stop", b"", request_type="shutdown"))
        stdout = io.BytesIO()
        self.assertEqual(worker.serve(stdin, stdout, engine), 0)
        self.assertEqual(engine.calls, [])
```

Also migrate the four `_remove_aggregate_boxes` assertions from `test_bread_vision_detector.py` so postprocessing behavior is preserved.

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.test_bread_box_worker -v
```

Expected: FAIL because `tools/detectors/bread_box_worker.py` does not exist.

- [ ] **Step 3: Implement framing and the coordinate-only engine**

Create `tools/detectors/bread_box_worker.py` with these exact public constants and functions:

```python
PROTOCOL_VERSION = 1
MAX_HEADER_BYTES = 64 * 1024
MAX_IMAGE_BYTES = 512 * 1024 * 1024
MAX_RESPONSE_BYTES = 1024 * 1024


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
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(encoded) > MAX_RESPONSE_BYTES:
        raise ValueError("response exceeds 1 MiB")
    stream.write(struct.pack(">I", len(encoded)))
    stream.write(encoded)
    stream.flush()
```

Implement `BreadBoxEngine.detect_bytes` using `np.frombuffer` and `cv2.imdecode`, then reuse the existing detection extraction and aggregate-box removal logic. Construct only one Ultralytics `YOLO(args.detector_model)` in `main`; do not accept or import classifier/CLIP settings. Emit this ready frame after model construction:

```python
write_json_frame(sys.stdout.buffer, {
    "version": PROTOCOL_VERSION,
    "type": "ready",
    "detectorName": "bread-yolo-boxes",
    "model": Path(args.detector_model).name,
})
```

`serve` must map `decode_failed` without terminating the worker and `inference_failed` as a request error that Dart may recover by restarting:

```python
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
            write_json_frame(stdout, {
                "version": PROTOCOL_VERSION,
                "type": "result",
                "requestId": request_id,
                "image": {"width": result["width"], "height": result["height"]},
                "boxes": result["boxes"],
            })
        except DecodeError as error:
            write_json_frame(stdout, {
                "version": PROTOCOL_VERSION,
                "type": "error",
                "requestId": request_id,
                "code": "decode_failed",
                "message": str(error),
            })
        except Exception as error:
            write_json_frame(stdout, {
                "version": PROTOCOL_VERSION,
                "type": "error",
                "requestId": request_id,
                "code": "inference_failed",
                "message": str(error),
            })
```

- [ ] **Step 4: Add malformed-frame, decode, and max-proposal tests**

Add these exact test cases:

- `test_truncated_payload_raises_eof_error`: declare five payload bytes, provide two, and assert `EOFError` contains `expected 5 bytes`.
- `test_oversized_header_is_rejected`: write a header length of `MAX_HEADER_BYTES + 1` and assert `ValueError` contains `64 KiB` before header allocation.
- `test_corrupt_image_returns_decode_failed_and_keeps_worker_alive`: send corrupt bytes followed by a valid fake-engine request; assert the first response code is `decode_failed` and the second response is `result`.
- `test_max_proposals_is_passed_per_request`: put `maxProposals: 7` in the header and assert `FakeEngine.calls` records `7`.
- `test_model_factory_is_called_once_for_two_requests`: construct one `BreadBoxEngine` with a counting YOLO factory, process two frames, and assert the factory count is `1`.

Use a 2x2 PNG generated with `cv2.imencode` for the successful memory-decode test; do not create a temporary source image path.

- [ ] **Step 5: Run Python tests**

Run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.test_bread_box_worker -v
```

Expected: all worker tests PASS and no classifier model is constructed.

- [ ] **Step 6: Task checkpoint**

Record the passing command and inspect only `bread_box_worker.py` plus its test. Do not delete the legacy sidecar until Task 7, so working postprocess logic remains available for comparison.

---

### Task 2: Dart Binary Worker Protocol

**Files:**
- Create: `C:\workspace\bbox\lib\detector\worker_protocol.dart`
- Create: `C:\workspace\bbox\test\detector\worker_protocol_test.dart`

**Interfaces:**
- Produces `WorkerByteReader(Stream<List<int>> source)` with `Future<Uint8List> readExactly(int count)`.
- Produces `WorkerMessage` containing `type`, `requestId`, and decoded JSON.
- Produces `Future<void> writeWorkerRequest(IOSink sink, Map<String, Object?> header, int payloadLength, Stream<List<int>> payload)`.
- Produces `Future<WorkerMessage> readWorkerMessage(WorkerByteReader reader)`.

- [ ] **Step 1: Write fragmented-stream and framing tests**

Create `test/detector/worker_protocol_test.dart`:

```dart
test('reads a response split across arbitrary chunks', () async {
  final jsonBytes = utf8.encode('{"version":1,"type":"ready"}');
  final frame = BytesBuilder()
    ..add(uint32Bytes(jsonBytes.length))
    ..add(jsonBytes);
  final bytes = frame.takeBytes();
  final reader = WorkerByteReader(Stream<List<int>>.fromIterable([
    bytes.sublist(0, 2),
    bytes.sublist(2, 7),
    bytes.sublist(7),
  ]));

  final message = await readWorkerMessage(reader);

  expect(message.type, 'ready');
});

test('writes utf8 header and streams payload unchanged', () async {
  final chunks = <List<int>>[];
  final controller = StreamController<List<int>>();
  final subscription = controller.stream.listen(chunks.add);
  final sink = IOSink(controller.sink);
  await writeWorkerRequest(
    sink,
    const {'version': 1, 'type': 'detect', 'requestId': '7', 'fileName': '한글.png'},
    5,
    Stream<List<int>>.fromIterable(const [[1, 2], [3, 4, 5]]),
  );
  await sink.close();
  await subscription.asFuture<void>();
  expect(decodeRecordedPayload(chunks.expand((chunk) => chunk).toList()), [1, 2, 3, 4, 5]);
});
```

Use a real in-memory `IOSink` backed by `StreamController`; avoid starting a process or writing a temporary file.

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\detector\worker_protocol_test.dart
```

Expected: FAIL because `worker_protocol.dart` does not exist.

- [ ] **Step 3: Implement the protocol primitives**

Use these exact limits and message shape:

```dart
const workerProtocolVersion = 1;
const maxWorkerHeaderBytes = 64 * 1024;
const maxWorkerImageBytes = 512 * 1024 * 1024;
const maxWorkerResponseBytes = 1024 * 1024;

class WorkerProtocolException implements Exception {
  WorkerProtocolException(this.message);
  final String message;
  @override
  String toString() => 'WorkerProtocolException: $message';
}

class WorkerMessage {
  const WorkerMessage(this.json);
  final Map<String, Object?> json;
  String get type => json['type'] as String? ?? '';
  String? get requestId => json['requestId']?.toString();
}
```

Implement `WorkerByteReader` with a `StreamIterator<List<int>>`, a current chunk, and an offset so fragmented reads preserve leftover bytes. Use `ByteData(4)..setUint32(0, value, Endian.big)` and `ByteData(8)..setUint64(0, value, Endian.big)` for lengths. `writeWorkerRequest` must validate `payloadLength`, write header and length prefixes, then call `sink.addStream(payload)` and `sink.flush()` without Base64 encoding.

- [ ] **Step 4: Add negative tests**

Add these exact test cases:

- `rejects response larger than one MiB`: frame a length of `maxWorkerResponseBytes + 1` and expect `WorkerProtocolException` before reading a body.
- `rejects unsupported protocol version`: frame `{"version":2,"type":"ready"}` and expect the exception message to contain `version`.
- `throws on truncated response body`: declare ten bytes, emit three, close the stream, and expect the exception message to contain `truncated`.
- `rejects payload larger than 512 MiB before writing`: pass `maxWorkerImageBytes + 1` with an empty stream and verify the sink receives zero bytes.

- [ ] **Step 5: Run protocol tests**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\detector\worker_protocol_test.dart
```

Expected: all protocol tests PASS.

- [ ] **Step 6: Task checkpoint**

Confirm `rg -n "base64|Base64" lib/detector/worker_protocol.dart` returns no matches and save the passing test output.

---

### Task 3: Bread Worker Process Client

**Files:**
- Create: `C:\workspace\bbox\lib\detector\bread_worker_client.dart`
- Create: `C:\workspace\bbox\test\detector\bread_worker_client_test.dart`
- Use: `C:\workspace\bbox\lib\detector\worker_protocol.dart`

**Interfaces:**
- Produces `BreadWorkerHandle` abstraction for fake and real processes.
- Produces `BreadWorkerClient.start()` that waits for `ready`.
- Produces `BreadWorkerClient.detect({required String requestId, required String fileName, required int payloadLength, required Stream<List<int>> payload, int? maxProposals}) -> Future<Map<String, Object?>>`.
- Produces `BreadWorkerClient.shutdown()` and `kill()`.
- Exposes `List<String> get recentStderr` capped at 50 lines.

- [ ] **Step 1: Write ready-handshake and reuse tests**

Define the test seam first:

```dart
abstract interface class BreadWorkerHandle {
  IOSink get stdin;
  Stream<List<int>> get stdoutBytes;
  Stream<String> get stderrLines;
  Future<int> get exitCode;
  bool kill();
}

typedef BreadWorkerStarter = Future<BreadWorkerHandle> Function(
  String executable,
  List<String> arguments,
);
```

Create fake handle tests with these exact assertions:

- `start waits for ready and detect reuses the same process`: keep `start()` incomplete until the fake emits `ready`, run two detects, and assert the starter count remains `1`.
- `start rejects result before ready`: emit a framed `result` as the first message and expect `WorkerProtocolException` containing `ready`.
- `detect rejects mismatched request id`: request ID `7`, respond with ID `8`, and expect `WorkerProtocolException` containing `requestId`.
- `stderr ring buffer retains only the latest fifty lines`: emit strings `line-0` through `line-59` and assert the retained list starts at `line-10` and ends at `line-59`.

The fake stdout must emit framed bytes through a `StreamController<List<int>>` and parse written stdin requests so it can respond with matching request IDs.

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\detector\bread_worker_client_test.dart
```

Expected: FAIL because `BreadWorkerClient` is undefined.

- [ ] **Step 3: Implement process startup and ready handshake**

Use this constructor and public methods:

```dart
class BreadWorkerClient {
  BreadWorkerClient({
    required this.pythonExecutable,
    required this.scriptPath,
    required this.modelPath,
    this.startTimeout = const Duration(seconds: 90),
    this.inferenceTimeout = const Duration(seconds: 120),
    BreadWorkerStarter? startWorker,
  }) : _startWorker = startWorker ?? _defaultStartWorker;

  final String pythonExecutable;
  final String scriptPath;
  final String modelPath;
  final Duration startTimeout;
  final Duration inferenceTimeout;

  Future<void> start();
  Future<Map<String, Object?>> detect({
    required String requestId,
    required String fileName,
    required int payloadLength,
    required Stream<List<int>> payload,
    int? maxProposals,
  });
  Future<void> shutdown();
  Future<void> kill();
}
```

Start arguments must be only:

```dart
[scriptPath, '--detector-model', modelPath]
```

Do not pass image paths, classifier paths, or FastSAM settings. `start()` must subscribe to stderr, build one `WorkerByteReader`, read exactly one `ready` message, and time out after `startTimeout`.

- [ ] **Step 4: Implement detect and shutdown**

`detect` must write one framed request, read one framed response, validate request ID, return the JSON for `result`, and throw typed exceptions:

```dart
class WorkerRequestException implements Exception {
  WorkerRequestException(this.code, this.message);
  final String code;
  final String message;
  bool get retryable => code == 'inference_failed';
}
```

For `shutdown`, send a zero-payload request, close stdin, wait two seconds for `exitCode`, and kill if the wait times out.

- [ ] **Step 5: Add exit, timeout, and shutdown tests**

Add these exact test cases:

- `detect surfaces process exit as a transport failure`: close fake stdout and complete exit code `5` before a response; expect a transport exception containing exit code `5`.
- `detect times out using injected duration`: inject a one-millisecond inference timeout, emit no response, and expect `TimeoutException`.
- `decode_failed is non-retryable`: emit an error frame with code `decode_failed` and assert `WorkerRequestException.retryable` is false.
- `inference_failed is retryable`: emit code `inference_failed` and assert `retryable` is true.
- `shutdown kills process after two-second timeout`: inject a short shutdown timeout for the test, leave exit code incomplete, and assert fake handle `killCalls` is `1`.

- [ ] **Step 6: Run client and protocol tests**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\detector\worker_protocol_test.dart test\detector\bread_worker_client_test.dart
```

Expected: all tests PASS.

- [ ] **Step 7: Task checkpoint**

Confirm the real process starter uses `Process.start`, exposes byte stdout without UTF-8 decoding, and decodes only stderr as lines.

---

### Task 4: Auto Box Service State, Streaming, and Retry

**Files:**
- Create: `C:\workspace\bbox\lib\detector\auto_box_service.dart`
- Create: `C:\workspace\bbox\test\detector\auto_box_service_test.dart`
- Use: `C:\workspace\bbox\lib\detector\detector.dart`
- Use: `C:\workspace\bbox\lib\detector\bread_worker_client.dart`

**Interfaces:**
- Produces `enum AutoBoxState { idle, starting, ready, running, restarting, failed }`.
- Produces `ImagePayload` and injectable `ImagePayloadOpener`.
- Produces `AutoBoxRuntime implements Detector, Listenable` as the controller and test boundary.
- Produces `AutoBoxService extends ChangeNotifier implements AutoBoxRuntime`.
- Produces `defaultAutoBoxService({Map<String, String>? environment, bool Function(String path)? fileExists, String? executablePath})` with app-local runtime, worker, and model path resolution.

- [ ] **Step 1: Write state and warm-up deduplication tests**

Use this interface in `auto_box_service_test.dart`:

```dart
class ImagePayload {
  const ImagePayload({required this.length, required this.bytes});
  final int length;
  final Stream<List<int>> bytes;
}

typedef ImagePayloadOpener = Future<ImagePayload> Function(String path);
typedef BreadWorkerClientFactory = BreadWorkerClient Function();
```

Write these exact tests:

- `concurrent warmUp calls start one client`: call `warmUp()` twice before completing fake start and assert factory and start counts are `1`.
- `warmUp transitions idle starting ready`: record listener snapshots and assert the ordered sequence is `idle`, `starting`, `ready`.
- `startup failure transitions to failed without fallback`: throw from fake start, assert state `failed`, and assert factory count is `1`.

Use a fake client factory with start counters; do not start Python.

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\detector\auto_box_service_test.dart
```

Expected: FAIL because `AutoBoxService` is undefined.

- [ ] **Step 3: Implement against the existing detector contract**

Keep the existing `Detector` signature through Tasks 4-6 so the replacement service can be verified before legacy implementations are deleted. `AutoBoxService.detect` temporarily accepts the optional `Map<String, int> labelByName = const {}` parameter for interface compatibility but never reads it or sends it to Python.

Do not change `DummyDetector`, `DarkBackgroundDetector`, legacy sidecar classes, or test fake signatures yet. Task 7 removes legacy implementations and then simplifies the shared interface in one independently testable change.

- [ ] **Step 4: Implement AutoBoxService warm-up and state notifications**

Use this public shape:

```dart
abstract interface class AutoBoxRuntime implements Detector, Listenable {
  AutoBoxState get state;
  Object? get lastError;
  List<String> get recentStderr;
  Future<void> warmUp();
  Future<void> shutdown();
}
```

Implement `AutoBoxService extends ChangeNotifier implements AutoBoxRuntime` with constructor parameters `required BreadWorkerClientFactory createClient` and optional `ImagePayloadOpener openImage`. Its name is exactly `bread-yolo-boxes`; state, last error, recent stderr, warm-up, detect, and shutdown satisfy the interface above. `shutdown()` must be idempotent.

Cache one `_warmUpFuture`; clear it after completion while retaining the ready client. A failed manual `warmUp()` may create one new client on the next call.

- [ ] **Step 5: Write retry-policy tests before detect implementation**

Add these exact tests:

- `two successful detections reuse one client`: detect two images sequentially and assert client factory count `1`, start count `1`, detect count `2`.
- `transport failure restarts once and reopens image once`: first client throws a transport exception; second succeeds; assert factory count `2` and image opener count `2`.
- `second retry failure does not start a third client`: both clients throw; assert factory count `2`, state `failed`, and no third start.
- `decode_failed does not restart worker`: client throws non-retryable `WorkerRequestException`; assert factory count `1` and opener count `1`.
- `file open failure does not restart worker`: opener throws `FileSystemException`; assert client detect count `0` and state returns to `ready`.
- `image larger than 512 MiB fails before client detect`: opener reports `maxWorkerImageBytes + 1`; assert detect count `0`.
- `concurrent detect calls do not create a second request`: start one incomplete detect, call detect again, assert the second call throws `AutoBoxBusyException`, and assert client detect count remains `1`.

The opener counter must prove that retry reopens the file instead of retaining the whole image in memory.

- [ ] **Step 6: Implement streamed detect and one retry**

Add `class AutoBoxBusyException implements Exception { const AutoBoxBusyException(); }` and implement detection as:

```dart
Future<DetectionResult> detect(
  AnnotatedImage image, {
  String? imagePath,
  DetectionOptions options = const DetectionOptions(),
  Map<String, int> labelByName = const {},
}) async {
  final path = imagePath ?? image.sourcePath;
  if (_isDetecting) throw AutoBoxBusyException();
  _isDetecting = true;
  try {
    return await _detectOnceWithRecovery(image, path, options);
  } finally {
    _isDetecting = false;
  }
}
```

`_detectOnceWithRecovery` must:

1. Await the shared warm-up.
2. Open the file and stream it once.
3. On retryable worker/transport/protocol failure, set `restarting`, kill the client, start exactly one new client, reopen the file, use a new request ID, and resend once.
4. Map response boxes to clamped `BoundingBox` values with `proposal` status and null label.
5. Treat `decode_failed`, file errors, and oversize images as non-retryable.
6. Return to `ready` after success; move to `failed` after final worker failure.

- [ ] **Step 7: Implement default path resolution**

`defaultAutoBoxService` must prefer paths beside `Platform.resolvedExecutable`, then workspace absolute paths for development:

```text
runtime/python/python.exe
tools/detectors/bread_box_worker.py
models/bread_yolov8n_1class_tray_v0_2.pt
```

Support only these overrides:

```text
BBOX_BREAD_PYTHON
BBOX_BREAD_WORKER
BBOX_BREAD_DETECTOR_MODEL
```

Do not retain `BBOX_FASTSAM_*`, classifier, or CLIP variables.

Add path tests that pass a fake `fileExists`: app-local runtime/worker/model win over workspace paths; environment overrides win over app-local paths; missing required assets cause warm-up failure rather than selecting another detector.

- [ ] **Step 8: Run detector service tests**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\detector\worker_protocol_test.dart test\detector\bread_worker_client_test.dart test\detector\auto_box_service_test.dart test\detector\dark_background_detector_test.dart
```

Expected: all tests PASS.

- [ ] **Step 9: Task checkpoint**

Search production Dart detector code:

```powershell
rg -n "labelByName|classifier|clipReference|FastSAM" lib\detector
```

Expected at this checkpoint: legacy classes may still match in `detector.dart`; all new service/client files have no matches.

---

### Task 5: AppController Integration and Safe Project Mutation

**Files:**
- Modify: `C:\workspace\bbox\lib\ui\app_controller.dart`
- Modify: `C:\workspace\bbox\test\ui\app_controller_auto_box_test.dart`
- Modify: `C:\workspace\bbox\test\ui\app_controller_test.dart`
- Modify: `C:\workspace\bbox\test\integration\mvp_flow_test.dart`
- Create: `C:\workspace\bbox\test\support\fake_auto_box_runtime.dart`

**Interfaces:**
- `AppController` accepts `AutoBoxRuntime? autoBoxRuntime`.
- Produces `AutoBoxState get autoBoxState`, `bool get canRunAutoBoxes`, `Future<void> warmUpAutoBoxes()`, and `Future<void> shutdownAutoBoxes()`.
- `detectSelectedImage({Detector? detector, DetectionOptions options})` uses injected detector only for tests and the service by default.

- [ ] **Step 1: Replace progress-detector tests with service-state tests**

Create `test/support/fake_auto_box_runtime.dart` implementing `AutoBoxRuntime` with controllable state, warm-up/detect/shutdown counters, and optional completers. In `app_controller_auto_box_test.dart`, remove `ProgressDetector` and the per-click `loadingModel` assertion. Add these exact tests:

- `controller exposes auto box service state`: set fake state to `restarting`, notify listeners, and assert controller state plus listener notification.
- `controller warmUp delegates once to service`: call `warmUpAutoBoxes()` and assert fake warm-up count `1`.
- `failed service remains manually retryable`: begin in `failed`, invoke detection, assert fake warm-up/start is called and the successful result is applied.

- [ ] **Step 2: Write stale-result and preservation tests**

Add these exact tests:

- `result is discarded when project changes during detection`: start a completer-backed detection, replace the controller project, complete with one box, and assert the replacement project is unchanged.
- `result is discarded when selected image changes during detection`: start on image `1`, select image `2`, complete with one box, and assert neither image is mutated.
- `service failure preserves boxes selection status and undo depth`: snapshot selected box and `canUndo`, throw, and assert both plus all boxes/status equal the snapshot.
- `zero boxes replaces previous boxes and remains undoable`: return an empty successful result, assert boxes empty, call Undo, and assert original boxes return.

Capture the project file path or library project ID plus selected image ID before awaiting detection; the fake detector completer resolves after the test changes selection/project.

- [ ] **Step 3: Run controller tests and verify new cases fail**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\ui\app_controller_auto_box_test.dart test\ui\app_controller_test.dart
```

Expected: new service-state and stale-result tests FAIL.

- [ ] **Step 4: Integrate AutoBoxService into AppController**

Add fields and constructor wiring:

```dart
AppController({
  ProjectLibrary? projectLibrary,
  AutoBoxRuntime? autoBoxRuntime,
}) : _projectLibrary = projectLibrary ?? ProjectLibrary.appData(),
     _autoBoxRuntime = autoBoxRuntime ?? defaultAutoBoxService() {
  _autoBoxRuntime.addListener(_handleAutoBoxRuntimeChanged);
}

AutoBoxState get autoBoxState => _autoBoxRuntime.state;
Future<void> warmUpAutoBoxes() => _autoBoxRuntime.warmUp();
Future<void> shutdownAutoBoxes() => _autoBoxRuntime.shutdown();
```

`canRunAutoBoxes` must require a valid selected image, no current automation, and service state `ready` or `failed`. A failed state means clicking performs manual warm-up retry through `detect`.

Constructor injection transfers runtime ownership to `AppController`. Override `dispose()` to remove `_handleAutoBoxRuntimeChanged`, call `unawaited(_autoBoxRuntime.shutdown())`, and then call `super.dispose()`. `AutoBoxService.shutdown()` is idempotent so an earlier detached lifecycle shutdown is safe.

- [ ] **Step 5: Update detectSelectedImage without destructive early mutation**

Before awaiting detection, capture:

```dart
final requestProjectId = _currentLibraryProjectId ?? project.projectFilePath ?? project.name;
final requestImageId = image.id;
final previousProject = project;
final previousSelectedBoxId = _selectedBoxId;
```

After the result returns, verify both project identity and selected image ID still match. If not, return without Undo, replacement, save, or user-success message. On returned or thrown failure, restore the previous project and selected box ID and add no Undo entry. Keep `_asUnlabeledProposals` as defense in depth.

- [ ] **Step 6: Keep coordinate-only controller behavior with the compatible signature**

Do not build or pass a project label map from the controller. Keep the temporary optional `labelByName` parameter on fakes until Task 7. Replace tests that expect sidecar labels with a defense-in-depth test that a malicious/pre-labeled fake result is still converted to proposals.

- [ ] **Step 7: Run controller and integration tests**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\ui\app_controller_auto_box_test.dart test\ui\app_controller_test.dart test\integration\mvp_flow_test.dart
```

Expected: all tests PASS.

- [ ] **Step 8: Task checkpoint**

Confirm failure and stale-result paths leave `_undoStack`, selected box, project boxes, and autosave scheduling unchanged.

---

### Task 6: Startup Warm-Up, Shutdown, and Workbench UI State

**Files:**
- Modify: `C:\workspace\bbox\lib\ui\bbox_app.dart`
- Modify: `C:\workspace\bbox\lib\ui\workbench_copy.dart`
- Modify: `C:\workspace\bbox\lib\ui\workbench\center_toolbar.dart`
- Modify: `C:\workspace\bbox\lib\ui\workbench\workbench_screen.dart`
- Modify: `C:\workspace\bbox\test\widget_test.dart`
- Modify: `C:\workspace\bbox\test\ui\project_home_widget_test.dart`
- Modify: `C:\workspace\bbox\test\ui\workbench\center_toolbar_test.dart`
- Use: `C:\workspace\bbox\test\support\fake_auto_box_runtime.dart`

**Interfaces:**
- `BboxApp` starts `controller.warmUpAutoBoxes()` in `initState` using `unawaited`.
- App-owned controllers shut down the worker on widget disposal; `AppLifecycleState.detached` also requests shutdown.
- Toolbar maps `AutoBoxState` to approved copy and enabled state.

- [ ] **Step 1: Write startup non-blocking tests**

Create a fake service whose `warmUp()` returns an incomplete `Completer<void>` and inject it through `AppController`. Add to `widget_test.dart`:

```dart
testWidgets('first paint does not wait for detector warm up', (tester) async {
  final runtime = FakeAutoBoxRuntime.pendingWarmUp();
  final controller = AppController(autoBoxRuntime: runtime, projectLibrary: memoryLibrary);
  await tester.pumpWidget(BboxApp(controller: controller));
  await tester.pump();
  expect(find.byKey(const ValueKey('project-home')), findsOneWidget);
  expect(runtime.warmUpCalls, 1);
});
```

Add a detached-lifecycle test proving shutdown is requested exactly once on the injected fake runtime. Update every existing `AppController` constructed by `widget_test.dart` and `project_home_widget_test.dart` to inject `FakeAutoBoxRuntime.ready()` so those tests never launch the bundled Python runtime, and register `addTearDown(controller.dispose)` because the test owns externally injected controllers.

- [ ] **Step 2: Write toolbar-state tests**

In `center_toolbar_test.dart`, add one test per state:

- `starting shows disabled model preparation action`: assert text `모델 준비 중` and a null button callback.
- `ready shows enabled automatic box action`: assert text `자동 박스` and a non-null callback.
- `running shows disabled detection action`: assert text `자동 박스 찾는 중` and a null callback.
- `restarting shows disabled restart action`: assert text `모델 다시 시작 중` and a null callback.
- `failed shows enabled retry action`: assert text `자동 박스 다시 시도` and a non-null callback that increments fake detection count.

- [ ] **Step 3: Run widget tests and verify they fail**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\widget_test.dart test\ui\workbench\center_toolbar_test.dart
```

Expected: new startup and state-copy tests FAIL.

- [ ] **Step 4: Add lifecycle warm-up and shutdown**

Make `_BboxAppState` a `WidgetsBindingObserver`. Initialize explicitly:

```dart
late final AppController _controller;
late final bool _ownsController;

@override
void initState() {
  super.initState();
  _ownsController = widget.controller == null;
  _controller = widget.controller ?? AppController();
  WidgetsBinding.instance.addObserver(this);
  unawaited(_controller.warmUpAutoBoxes());
}

@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.detached) {
    unawaited(_controller.shutdownAutoBoxes());
  }
}
```

In `dispose`, remove the observer and dispose only an app-owned controller; `AppController.dispose()` shuts down its runtime. Externally injected test controllers remain owned by their tests and are disposed through test teardown. The detached lifecycle callback may call `shutdownAutoBoxes()` earlier, relying on idempotent service shutdown.

- [ ] **Step 5: Add approved copy and toolbar mapping**

Add constants:

```dart
static const autoBoxesPreparingModel = '모델 준비 중';
static const autoBoxesRestartingModel = '모델 다시 시작 중';
static const autoBoxesRetry = '자동 박스 다시 시도';
static const autoBoxesModelUnavailable = '자동 박스 모델을 준비하지 못했습니다.';
```

In `_CenterAutoBoxesToolbar`, derive label and callback from `controller.autoBoxState`; do not show the old `autoBoxesLoadingModel` message. Gate `_handleAutoBoxesShortcut` with `controller.canRunAutoBoxes` so keyboard and button behavior match.

- [ ] **Step 6: Run widget tests**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\widget_test.dart test\ui\workbench\center_toolbar_test.dart test\ui\workbench\workbench_shell_test.dart
```

Expected: all tests PASS.

- [ ] **Step 7: Task checkpoint**

Manually confirm the project-home screen renders while the fake warm-up Future remains incomplete and that no modal appears.

---

### Task 7: Remove Legacy Detectors and Harden Windows Packaging

**Files:**
- Modify: `C:\workspace\bbox\lib\detector\detector.dart`
- Modify: `C:\workspace\bbox\test\detector\dummy_detector_test.dart`
- Delete: `C:\workspace\bbox\tools\detectors\fastsam_detector.py`
- Delete: `C:\workspace\bbox\tools\detectors\bread_vision_detector.py`
- Delete: `C:\workspace\bbox\test\tools\test_bread_vision_detector.py`
- Delete: `C:\workspace\bbox\FastSAM-s.pt`
- Modify: `C:\workspace\bbox\windows\CMakeLists.txt`
- Modify: `C:\workspace\bbox\tools\packaging\build_windows_installer.ps1`
- Modify: `C:\workspace\bbox\installer\bbox_labeler.iss`
- Modify: `C:\workspace\bbox\test\packaging\installer_script_test.dart`
- Modify: `C:\workspace\bbox\test\ui\workbench\canvas_overlay_test.dart`
- Modify: `C:\workspace\bbox\README.md`
- Modify: `C:\workspace\bbox\docs\release-checklist.md`
- Modify: `C:\workspace\bbox\models\README.md`
- Modify: `C:\workspace\bbox\docs\project-structure.md`

**Interfaces:**
- `detector.dart` contains no subprocess sidecar implementation.
- Windows build copies exactly one worker script and one detector model.
- Installer helper requires runtime, worker, and tray detector model without an allow-missing switch.
- Upgrades delete stale FastSAM, classifier, and one-shot sidecar assets.

- [ ] **Step 1: Update packaging tests first**

Replace `installer helper requires safe bread detector assets` with:

```dart
test('installer helper requires coordinate-only worker assets', () {
  final script = File('tools/packaging/build_windows_installer.ps1').readAsStringSync();
  expect(script, contains('tools\\detectors\\bread_box_worker.py'));
  expect(script, contains('models\\bread_yolov8n_1class_tray_v0_2.pt'));
  expect(script, isNot(contains('bread_classifier')));
  expect(script, isNot(contains('FastSAM')));
  expect(script, isNot(contains('AllowMissingDetectorRuntime')));
});

test('installer upgrade removes stale detector assets', () {
  final script = File('installer/bbox_labeler.iss').readAsStringSync();
  for (final stale in [
    r'{app}\FastSAM-s.pt',
    r'{app}\tools\detectors\fastsam_detector.py',
    r'{app}\tools\detectors\bread_vision_detector.py',
    r'{app}\models\bread_classifier_yolov8n_cls_best.pt',
  ]) {
    expect(script, contains(stale));
  }
});
```

Add a test reading `windows/CMakeLists.txt` and asserting it names only `bread_box_worker.py` and the tray detector model in active install rules.

- [ ] **Step 2: Run packaging tests and verify they fail**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\packaging\installer_script_test.dart
```

Expected: FAIL on old script/model names and allow-missing behavior.

- [ ] **Step 3: Delete legacy runtime files and classes**

Delete FastSAM, the one-shot/classifier bread sidecar, its old Python test, and root FastSAM weights. Remove these Dart classes and helpers from `detector.dart`:

```text
FastSamSidecarDetector
BreadVisionSidecarDetector
PersistentBreadVisionSidecarDetector
ProgressReportingDetector
DetectionProgress
DetectionProgressStage
DetectionProgressCallback
BreadWorkerHandle
ProcessResultLike
defaultImportDetector
_breadVisionArguments
_parseSidecarBoxes
_friendlySidecarError
```

Retain `DetectionResult`, `DetectionOptions`, `boundedMaxProposals`, `Detector`, `DummyDetector`, and non-sidecar algorithmic detectors. Rewrite `dummy_detector_test.dart` to test only those retained contracts; worker/service behavior now belongs to the new focused test files.

After deleting all legacy implementations, simplify `Detector.detect` by removing `labelByName` and remove the temporary ignored parameter from `AutoBoxService`, all fakes, and integration tests. Change the literal `FastSAM sidecar failed` fixture in `canvas_overlay_test.dart` to `자동 박스 worker failed` so active tests no longer retain obsolete product terminology.

- [ ] **Step 4: Make CMake copy exact assets and remove stale output**

Replace broad model-directory installation and FastSAM rules with:

```cmake
install(CODE "
  file(REMOVE
    \"${CMAKE_INSTALL_PREFIX}/FastSAM-s.pt\"
    \"${CMAKE_INSTALL_PREFIX}/tools/detectors/fastsam_detector.py\"
    \"${CMAKE_INSTALL_PREFIX}/tools/detectors/bread_vision_detector.py\"
    \"${CMAKE_INSTALL_PREFIX}/models/bread_classifier_yolov8n_cls_best.pt\")
  " COMPONENT Runtime)

set(BBOX_BREAD_WORKER_FILE "${CMAKE_CURRENT_SOURCE_DIR}/../tools/detectors/bread_box_worker.py")
if(EXISTS "${BBOX_BREAD_WORKER_FILE}")
  install(FILES "${BBOX_BREAD_WORKER_FILE}"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/tools/detectors" COMPONENT Runtime)
endif()

set(BBOX_BREAD_MODEL_FILE "${CMAKE_CURRENT_SOURCE_DIR}/../models/bread_yolov8n_1class_tray_v0_2.pt")
if(EXISTS "${BBOX_BREAD_MODEL_FILE}")
  install(FILES "${BBOX_BREAD_MODEL_FILE}"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/models" COMPONENT Runtime)
endif()
```

Do not install `models/*.pt` broadly.

- [ ] **Step 5: Make installer builds require the coordinate-only assets**

Remove `AllowMissingDetectorRuntime` from `build_windows_installer.ps1`. Require exactly:

```powershell
@(
  "runtime\python\python.exe",
  "tools\detectors\bread_box_worker.py",
  "models\bread_yolov8n_1class_tray_v0_2.pt"
)
```

After `flutter build windows --release`, fail if any forbidden file exists in Release. Add exact `[InstallDelete]` entries in `bbox_labeler.iss` for the four stale assets in the Step 1 test.

- [ ] **Step 6: Update active documentation**

README and release checklist must say:

- automatic boxes use a persistent coordinate-only bread YOLO worker;
- the app streams image bytes and does not give worker source paths;
- model warm-up begins at startup;
- runtime, worker, and tray model are mandatory for installer builds;
- two-image smoke verification must show one PID/model initialization;
- FastSAM and classifier are not release assets.

Update `models/README.md` so only `bread_yolov8n_1class_tray_v0_2.pt` is the runtime model. Keep historical `docs/superpowers` plans/specs unchanged.

- [ ] **Step 7: Run cleanup and packaging tests**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test test\detector\dummy_detector_test.dart test\packaging\installer_script_test.dart test\packaging\version_consistency_test.dart
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.test_bread_box_worker -v
```

Expected: all tests PASS.

- [ ] **Step 8: Verify forbidden active references**

Run:

```powershell
rg -n "FastSamSidecarDetector|fastsam_detector\.py|FastSAM-s\.pt|BreadVisionSidecarDetector|PersistentBreadVisionSidecarDetector|bread_classifier_yolov8n_cls_best|bread_vision_detector\.py" lib test tools windows installer README.md docs\release-checklist.md models\README.md
```

Expected: no matches. Historical documents under `docs/superpowers` and research scripts under `tools/experiments` are intentionally outside this active-reference scan.

- [ ] **Step 9: Task checkpoint**

List `tools/detectors`, root model artifacts, and active build rules. Confirm only the new worker and the tray detector are in the product path.

---

### Task 8: End-to-End Verification and Release Smoke

**Files:**
- Modify only if verification exposes a requirement gap in files already listed above.
- Record evidence in the task handoff; do not add generated runtime/build outputs to source documentation.

**Interfaces:**
- Consumes all Tasks 1-7.
- Produces evidence for unit, widget, integration, Windows release, local image, NAS image, worker restart, and forbidden-asset acceptance criteria.

- [ ] **Step 1: Format and analyze**

Run:

```powershell
& C:\tools\flutter\bin\dart.bat format lib test
& C:\tools\flutter\bin\flutter.bat analyze
```

Expected: formatter completes; analyzer reports no errors.

- [ ] **Step 2: Run the complete Python suite relevant to the worker**

Run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.test_bread_box_worker -v
```

Expected: all tests PASS.

- [ ] **Step 3: Run focused Flutter suites**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test `
  test\detector\worker_protocol_test.dart `
  test\detector\bread_worker_client_test.dart `
  test\detector\auto_box_service_test.dart `
  test\detector\dummy_detector_test.dart `
  test\ui\app_controller_auto_box_test.dart `
  test\ui\app_controller_test.dart `
  test\ui\workbench\center_toolbar_test.dart `
  test\integration\mvp_flow_test.dart `
  test\packaging\installer_script_test.dart
```

Expected: all focused tests PASS.

- [ ] **Step 4: Run the full Flutter suite**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat test
```

Expected: all tests PASS.

- [ ] **Step 5: Build Windows Release**

Run:

```powershell
& C:\tools\flutter\bin\flutter.bat build windows --release
```

Expected: exit code 0. Then verify:

```powershell
$release = 'C:\workspace\bbox\build\windows\x64\runner\Release'
@(
  "$release\runtime\python\python.exe",
  "$release\tools\detectors\bread_box_worker.py",
  "$release\models\bread_yolov8n_1class_tray_v0_2.pt"
) | ForEach-Object { if (-not (Test-Path -LiteralPath $_)) { throw "Missing: $_" } }
@(
  "$release\FastSAM-s.pt",
  "$release\tools\detectors\fastsam_detector.py",
  "$release\tools\detectors\bread_vision_detector.py",
  "$release\models\bread_classifier_yolov8n_cls_best.pt"
) | ForEach-Object { if (Test-Path -LiteralPath $_) { throw "Forbidden: $_" } }
```

Expected: no exception.

- [ ] **Step 6: Smoke-test two local image requests in one worker**

Use a small helper in the Python unit test module or a PowerShell-compatible test harness that starts the release worker, reads the framed `ready`, sends two encoded local-image payloads, and checks two `result` responses. Record PID and stderr initialization lines.

Expected:

- one worker PID for both requests;
- one model initialization;
- two valid result frames;
- no classifier or FastSAM initialization.

- [ ] **Step 7: Smoke-test NAS and Unicode paths through the Release app**

Open the current NAS project, run automatic boxes twice on images under a UNC path containing Korean text and spaces, and verify:

- Flutter reads and streams both images;
- worker PID remains stable;
- no Python file-open attempt uses the UNC path;
- bbox proposals appear;
- the second click does not show model loading.

- [ ] **Step 8: Verify one automatic restart**

While one detection is active, terminate the worker PID once. Verify the service enters `restarting`, creates exactly one new PID, reloads once, reopens the image, retries once, and returns a result. Repeat with a fake forced failure or terminate the replacement worker; verify no third worker starts and existing boxes remain unchanged.

- [ ] **Step 9: Verify input failures do not restart**

Disconnect the NAS or temporarily make the selected file unavailable before clicking automatic boxes. Verify worker PID does not change, existing boxes and Undo history remain unchanged, and the user sees the file/network guidance. Restore access and verify the next manual action succeeds.

- [ ] **Step 10: Build installer with mandatory assets**

Run:

```powershell
powershell -ExecutionPolicy Bypass -File tools\packaging\build_windows_installer.ps1 -SkipFlutterBuild
```

Expected: installer build succeeds. Temporarily point one required-path test at a missing fixture only in an isolated verification copy or use the packaging unit test; do not rename/delete the real model. Confirm the helper's missing-asset path fails clearly.

- [ ] **Step 11: Final active-reference scan**

Run:

```powershell
rg -n "FastSamSidecarDetector|fastsam_detector\.py|FastSAM-s\.pt|BreadVisionSidecarDetector|PersistentBreadVisionSidecarDetector|bread_classifier_yolov8n_cls_best|bread_vision_detector\.py" lib test tools\detectors windows installer README.md docs\release-checklist.md models\README.md
```

Expected: no matches.

- [ ] **Step 12: Final checkpoint**

Summarize the exact commands, pass counts, Release asset checks, local/NAS worker PID evidence, restart evidence, and any environment-only limitations. Because the workspace is not a Git repository, do not claim a commit or clean worktree.
