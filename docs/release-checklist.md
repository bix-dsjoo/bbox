# Release Checklist

Use this checklist before publishing a Windows installer for BBox Labeler.

## Required Checks

- Run `flutter test`.
- Prepare the mandatory automatic-box runtime:
  `powershell -ExecutionPolicy Bypass -File tools\packaging\prepare_windows_detector_runtime.ps1`.
- Run `flutter build windows --release`.
- Build the installer with:
  `powershell -ExecutionPolicy Bypass -File tools\packaging\build_windows_installer.ps1 -SkipFlutterBuild`.
- Confirm `build/windows/x64/runner/Release/bbox_labeler.exe` exists.
- Confirm `build/windows/x64/runner/Release/train` does not exist.
- Confirm these mandatory release assets exist:
  - `build/windows/x64/runner/Release/runtime/python/python.exe`
  - `build/windows/x64/runner/Release/tools/detectors/bread_box_worker.py`
  - `build/windows/x64/runner/Release/models/bread_yolov8n_1class_tray_v0_2.pt`
- Confirm the installer script excludes `train`, `datasets`, `outputs`,
  `qa_samples`, and `research`.
- Confirm Windows executable metadata does not contain `com.example`.
- Confirm the app icon is present at `windows/runner/resources/app_icon.ico`.
- Confirm FastSAM and classifier weights are absent because they are not
  release assets.
- Confirm the bundled detector runtime imports `torch`, `torchvision`, `cv2`,
  `numpy`, and `ultralytics`.
- Launch the app and confirm model warm-up begins during startup.
- Run automatic boxes on two images and confirm the app streams image bytes
  without exposing source paths to the worker.
- During that two-image smoke test, confirm both responses come from one worker
  PID and logs show one model initialization.
- Confirm installer assets exist:
  - `installer/bbox_labeler_setup.ico`
  - `installer/wizard_image.bmp`
  - `installer/wizard_small_image.bmp`
  - `LICENSE.txt`
  - `THIRD_PARTY_NOTICES.txt`

## Detector Runtime Pins

The internal detector runtime script defaults to:

- Python `3.12.8`
- torch `2.5.1`
- torchvision `0.20.1`
- ultralytics `8.3.40`
- opencv-python-headless `4.10.0.84`
- numpy `1.26.4`

## Installer Build

Install Inno Setup and compile:

```powershell
powershell -ExecutionPolicy Bypass -File tools\packaging\build_windows_installer.ps1 -SkipFlutterBuild
```

The installer helper fails unless the bundled Python runtime, coordinate-only
worker script, and tray detector model are all present.

The expected output is:

```text
dist/bbox_labeler_setup_1.0.3.exe
```

## Public Distribution

Before public release, replace the temporary publisher identity with the final
legal publisher name, add a real support URL, and sign both the executable and
installer with a code-signing certificate.

The current release package intentionally does not bundle `train/` data.
The app does not bundle bakery training images. Only the tray detector model is
a product runtime model; classifier and other research weights stay outside the
release.
