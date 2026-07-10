# BBox Labeler

BBox Labeler is a Windows desktop tool for creating COCO object detection
bounding-box annotations from local image folders.

The app is designed for fast local dataset work:

- Create and reopen local labeling projects.
- Import image folders without modifying the original images.
- Review detector proposal boxes or draw boxes manually.
- Create labels, assign label colors, and confirm reviewed images.
- Export labeled boxes as standard COCO JSON.

## Platform

The release target is Windows desktop. macOS and Linux can be considered later,
but the current installer and metadata are prepared for Windows.

## Data Policy

Original images are never modified. Project state is saved separately, and COCO
export includes only valid labeled boxes. Unlabeled proposal boxes are excluded
from COCO annotations.

The repository may contain development datasets, QA samples, and analysis
folders. These are not product runtime assets and must not be bundled in the
installer. In particular, the `train/` folder is intentionally excluded from
Windows release outputs.

## Project Structure

For a map of source folders, tests, packaging tools, local datasets, and generated artifacts, see `docs/project-structure.md`.

## Build

```powershell
flutter test
flutter build windows --release
```

The release executable is created at:

```text
build/windows/x64/runner/Release/bbox_labeler.exe
```

## Detector Runtime

Automatic box proposals use a persistent, coordinate-only bread YOLO worker.
The app starts model warm-up during application startup, streams image bytes to
the worker, and never gives the worker source image paths. The worker returns
only bounding-box coordinates and confidence values; labels remain a user
decision in the app.

For every installer build, prepare the bundled runtime before building:

```powershell
powershell -ExecutionPolicy Bypass -File tools\packaging\prepare_windows_detector_runtime.ps1
flutter build windows --release
```

The runtime is generated under `runtime/python/` and copied next to the app as
`runtime/python/python.exe`. Installer builds require that runtime executable,
`tools/detectors/bread_box_worker.py`, and
`models/bread_yolov8n_1class_tray_v0_2.pt`. Generated runtime files are
intentionally ignored by source control because they are large and
platform-specific.

FastSAM and classifier weights are research-only artifacts, not product runtime
or release assets.

The `train/` folder is still excluded from release output. It is development
sample data, not an automatic-box runtime asset.

Pinned detector runtime defaults:

- Python `3.12.8`
- torch `2.5.1`
- torchvision `0.20.1`
- ultralytics `8.3.40`
- opencv-python-headless `4.10.0.84`
- numpy `1.26.4`

## Installer

The Inno Setup script is:

```text
installer/bbox_labeler.iss
```

It expects the Flutter Windows release output to exist first. Installer assets
are stored in `installer/`, and the Windows application icon is stored in
`windows/runner/resources/app_icon.ico`.

For internal company distribution:

```powershell
powershell -ExecutionPolicy Bypass -File tools\packaging\prepare_windows_detector_runtime.ps1
powershell -ExecutionPolicy Bypass -File tools\packaging\build_windows_installer.ps1
```

The installer helper always requires the bundled Python runtime, the persistent
worker script, and the tray detector model. A release build fails when any of
those assets is missing or when a retired detector asset remains in the release
directory.

## Release Notes

Before publishing a setup executable, follow `docs/release-checklist.md`.
Internal distribution should keep `LICENSE.txt` and `THIRD_PARTY_NOTICES.txt`
with the installed app. Public distribution would need a final legal publisher,
support URL, code-signing certificate, and full license review.
