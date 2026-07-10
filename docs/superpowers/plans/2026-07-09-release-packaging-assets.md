# Release Packaging Assets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare BBox Labeler for a realistic Windows desktop installer by adding release-facing assets, product metadata, documentation, and excluding bundled train data.

**Architecture:** Keep the Flutter app binary name stable as `bbox_labeler.exe`, use Korean-facing product copy where users see the app, and keep installer/runtime packaging explicit. Generated image assets live under `assets/brand` and `installer`, while Windows executable metadata stays in `windows/runner/Runner.rc`.

**Tech Stack:** Flutter Windows, CMake, Inno Setup script, Windows resource metadata, deterministic generated PNG/BMP/ICO assets.

## Global Constraints

- Do not modify original image datasets or source `train/` data.
- Exclude `train/` from Windows Release outputs and installer payloads.
- Keep source changes narrowly scoped to packaging, metadata, release docs, and generated assets.
- The workspace is not a Git repository, so commit steps are not available.

---

### Task 1: Remove Bundled Train Data

**Files:**
- Modify: `windows/CMakeLists.txt`
- Modify: `installer/bbox_labeler.iss`

**Interfaces:**
- Consumes: existing Flutter Windows build layout.
- Produces: release output that does not copy `train/` unless a developer manually adds it outside this plan.

- [ ] Keep installer excludes for `train\*`, `datasets\*`, `outputs\*`, and other development-only folders.
- [ ] Clean stale `build/windows/x64/runner/Release/train` after verifying the path is inside the workspace build directory.

### Task 2: Add Release Metadata And Installer Assets

**Files:**
- Modify: `pubspec.yaml`
- Modify: `windows/runner/Runner.rc`
- Modify: `windows/runner/main.cpp`
- Create/modify: `assets/brand/*`
- Create/modify: `installer/*`

**Interfaces:**
- Consumes: existing Windows runner resource references.
- Produces: branded executable icon, installer icon, wizard images, license text, and release metadata.

- [ ] Generate a deterministic BBox Labeler mark using simple geometric image drawing.
- [ ] Save PNG/SVG brand masters under `assets/brand`.
- [ ] Replace `windows/runner/resources/app_icon.ico`.
- [ ] Save Inno-compatible wizard BMP assets under `installer`.
- [ ] Update Windows version metadata to remove `com.example`.
- [ ] Update the app window title to `BBox 라벨러`.

### Task 3: Add Release Documentation

**Files:**
- Modify: `README.md`
- Create: `LICENSE.txt`
- Create: `docs/release-checklist.md`

**Interfaces:**
- Consumes: project goal from `AGENTS.md`.
- Produces: user-facing project description and a repeatable release checklist.

- [ ] Replace Flutter template README with actual product summary, install/build notes, and data policy.
- [ ] Add a plain proprietary license placeholder suitable for private/internal distribution.
- [ ] Add a release checklist covering build, test, installer, train-data exclusion, and signing notes.

### Task 4: Verify

**Files:**
- Build/test outputs only.

**Interfaces:**
- Consumes: modified Flutter project.
- Produces: fresh evidence for packaging readiness.

- [ ] Run `flutter test`.
- [ ] Run `flutter build windows --release`.
- [ ] Confirm `build/windows/x64/runner/Release/train` does not exist.
- [ ] Confirm executable version metadata no longer contains `com.example`.
- [ ] If Inno Setup is unavailable, report that installer script is prepared but setup EXE cannot be regenerated on this machine.
