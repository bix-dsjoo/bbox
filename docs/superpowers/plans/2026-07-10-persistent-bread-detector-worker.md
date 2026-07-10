# Persistent Bread Detector Worker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce automatic box latency by keeping the bread YOLO detector/classifier loaded in a background Python worker.

**Architecture:** Add a JSONL worker mode to `bread_vision_detector.py` that loads models once and accepts repeated image requests over stdin. Add a Dart detector wrapper that starts the worker lazily, sends one request per auto-box action, parses one JSON response, and falls back to the existing one-shot sidecar when the worker fails.

**Tech Stack:** Flutter/Dart desktop app, `dart:io` process management, Python, Ultralytics YOLO CPU runtime.

## Global Constraints

- Do not modify or read-write `C:\workspace\bakery_vision`.
- Keep the current precision policy: boxes may be proposals, but labels are emitted only when confidence and margin thresholds pass.
- Do not add visible auto-state UI.
- COCO export continues to include only labeled boxes.
- CPU runtime must remain supported.

---

### Task 1: Python JSONL Worker Mode

**Files:**
- Modify: `tools/detectors/bread_vision_detector.py`
- Test: `test/detector/dummy_detector_test.dart` covers Dart command arguments; manual smoke covers Python worker mode.

**Interfaces:**
- Consumes: existing CLI args `--detector-model`, `--classifier-model`, thresholds.
- Produces: optional `--worker` mode. stdin line JSON: `{"id":"1","image":"C:\\path\\image.jpg"}`. stdout line JSON: `{"id":"1","ok":true,"result":{...}}` or `{"id":"1","ok":false,"error":"..."}`.

- [x] **Step 1: Add shared inference class**

Move one-image logic into `_BreadVisionEngine.detect_image(image_path)`.

- [x] **Step 2: Add worker loop**

When `--worker` is present, load the engine once, read stdin lines, return one compact JSON response per line, flush after each response.

- [x] **Step 3: Preserve one-shot CLI**

Without `--worker`, keep stdout as the original detector result JSON so the current release smoke command still works.

### Task 2: Dart Persistent Process Detector

**Files:**
- Modify: `lib/detector/detector.dart`
- Test: `test/detector/dummy_detector_test.dart`

**Interfaces:**
- Consumes: `BreadVisionSidecarDetector.detect(...)`.
- Produces: `PersistentBreadVisionSidecarDetector` with the same `Detector` interface and fallback to one-shot `BreadVisionSidecarDetector`.

- [x] **Step 1: Add test seam**

Add injectable worker process starter so tests can provide fake stdin/stdout.

- [x] **Step 2: Implement request/response**

Start Python with `--worker`, send JSON line per image, parse a single line response, map approved labels through `labelByName`.

- [x] **Step 3: Add fallback**

If worker start, write, parse, or response fails, stop the worker and run the existing one-shot detector for that request.

### Task 3: Default Detector Selection And Packaging Check

**Files:**
- Modify: `lib/detector/detector.dart`
- Modify: `docs/release-checklist.md`
- Test: `test/detector/dummy_detector_test.dart`

**Interfaces:**
- Consumes: bread assets detection in `defaultImportDetector`.
- Produces: default detector returns persistent worker when bread assets are present.

- [x] **Step 1: Prefer persistent detector**

Return the persistent worker detector when script/model assets exist.

- [x] **Step 2: Keep existing fallback**

If assets are missing, continue returning FastSAM fallback as before.

- [x] **Step 3: Verify**

Run focused detector tests, full Flutter tests, Windows release build, and a worker smoke test over two QA sample images.
