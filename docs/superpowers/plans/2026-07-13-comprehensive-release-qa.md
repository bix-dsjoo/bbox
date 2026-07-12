# BBox Labeler Comprehensive Release QA Execution Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Do not use subagents unless the user explicitly changes the repository instruction that prohibits delegation.

**Goal:** Build the current Git HEAD as a Windows Release, audit every approved functional and experience quality gate, fix every P0-P3 defect, and produce fresh evidence that the final Release is ready.

**Architecture:** The run is a gated loop: freeze a traceable Release baseline, execute automated and real-UI checks, record evidence, root-cause each finding, add the smallest regression test and correction, rebuild, and repeat affected gates. The final report is tied to one executable hash so evidence from an older build cannot be mixed into the result.

**Tech Stack:** Flutter 3.44.4 / Dart, Windows Release runner, PowerShell, bundled Python 3.12 detector runtime, Flutter unit/widget/integration tests, Computer Use for real Windows UI automation, COCO JSON validation.

## Global Constraints

- The only valid UI target is `C:\workspace\bbox\build\windows\x64\runner\Release\bbox_labeler.exe` built from the current Git HEAD.
- Never test an installed copy under `%LOCALAPPDATA%\Programs`.
- Preserve unrelated user changes and never open, modify, rename, or delete existing user projects.
- Use only the dedicated QA project and QA artifacts under `C:\workspace\bbox\outputs\qa\2026-07-13`.
- Never modify source images.
- Fix every reproducible P0, P1, P2, and P3 finding.
- Add a failing automated regression test before a correction whenever the behavior can be represented below the native Windows shell boundary.
- After every correction batch, run related tests, the complete test suite, static analysis, a fresh Release build, the original UI reproduction, and affected end-to-end scenarios.
- Do not claim completion while any approved check is unverified.
- Follow `C:\workspace\bbox\AGENTS.md` and `C:\workspace\bbox\docs\superpowers\specs\2026-07-10-comprehensive-release-qa-design.md` throughout the run.

## Run Artifact Layout

The execution creates these untracked or report artifacts:

- `outputs/qa/2026-07-13/baseline/` — commit, toolchain, executable metadata, hash, and release inventory.
- `outputs/qa/2026-07-13/datasets/small/` — 10-image UI dataset.
- `outputs/qa/2026-07-13/datasets/medium/` — 500-image performance dataset.
- `outputs/qa/2026-07-13/datasets/large/` — 2,000-image performance dataset.
- `outputs/qa/2026-07-13/exports/` — COCO outputs from fixed scenarios.
- `outputs/qa/2026-07-13/evidence/` — screenshots, accessibility excerpts, timings, and logs.
- `docs/qa/2026-07-13-release-qa-report.md` — final tracked QA report.

Product corrections use the existing module/test pairs:

| Area | Product files | Regression tests |
|---|---|---|
| Project lifecycle | `lib/project/project_store.dart`, `lib/project/project_library.dart`, `lib/ui/app_controller.dart` | `test/project/project_store_test.dart`, `test/project/project_library_test.dart`, `test/ui/app_controller_library_test.dart` |
| Image import | `lib/image_import/image_scanner.dart`, `lib/ui/image_import_picker.dart`, `lib/ui/image_folder_path_dialog.dart` | `test/image_import/image_scanner_test.dart`, `test/ui/image_import_picker_test.dart`, `test/ui/image_folder_path_dialog_test.dart` |
| Detector | `lib/detector/auto_box_service.dart`, `lib/detector/bread_worker_client.dart`, `lib/detector/worker_protocol.dart`, `tools/detectors/bread_box_worker.py` | `test/detector/auto_box_service_test.dart`, `test/detector/bread_worker_client_test.dart`, `test/detector/worker_protocol_test.dart`, `test/tools/test_bread_box_worker.py` |
| Annotation rules | `lib/annotation/models.dart`, `lib/annotation/annotation_rules.dart` | `test/annotation/annotation_rules_test.dart` |
| Canvas and coordinates | `lib/viewer/viewport_transform.dart`, `lib/ui/canvas_interaction.dart`, `lib/ui/workbench/image_canvas.dart` | `test/viewer/viewport_transform_test.dart`, `test/ui/canvas_interaction_test.dart`, `test/ui/workbench/canvas_interaction_test.dart`, `test/ui/workbench/canvas_overlay_test.dart` |
| Workbench UX | `lib/ui/workbench/*.dart`, `lib/ui/workbench_copy.dart`, `lib/ui/app_theme.dart` | `test/ui/workbench/*.dart`, `test/widget_test.dart` |
| Labels | `lib/ui/label_management_popover.dart`, `lib/ui/workbench_label_selector.dart`, `lib/annotation/models.dart` | `test/ui/label_management_popover_test.dart`, `test/ui/workbench_label_selector_test.dart`, `test/annotation/label_shortcut_migration_test.dart` |
| COCO export | `lib/export/coco_exporter.dart` | `test/export/coco_exporter_test.dart`, `test/integration/mvp_flow_test.dart`, `test/ui/workbench/export_and_completion_test.dart` |
| Packaging | `windows/runner/*`, `installer/bbox_labeler.iss`, `tools/packaging/*.ps1` | `test/packaging/installer_script_test.dart`, `test/packaging/version_consistency_test.dart` |

---

### Task 1: Freeze the Traceable Baseline

**Files:**
- Read: `pubspec.yaml`
- Read: `.dart_tool/package_config.json`
- Create during execution: `outputs/qa/2026-07-13/baseline/*.txt`

**Interfaces:**
- Consumes: current Git repository and `C:\tools\flutter\bin\flutter.bat`.
- Produces: one baseline identity used by every later task.

- [ ] **Step 1: Confirm repository state before mutation**

Run:

```powershell
git status --short
git rev-parse HEAD
git log -1 --format="%H %ad %s" --date=iso
```

Expected: the full commit is recorded; any pre-existing changes are listed and preserved. If changes overlap a future correction, stop that correction and resolve scope with the user.

- [ ] **Step 2: Confirm the configured Flutter SDK**

Run:

```powershell
Select-String -Path .dart_tool\package_config.json -Pattern 'flutterRoot|flutterVersion'
& 'C:\tools\flutter\bin\flutter.bat' --version
```

Expected: the package configuration resolves to `C:\tools\flutter`, and Flutter/Dart versions print successfully.

- [ ] **Step 3: Create the run artifact directories**

Run:

```powershell
$root = 'C:\workspace\bbox\outputs\qa\2026-07-13'
@('baseline','datasets\small','datasets\medium','datasets\large','exports','evidence') |
  ForEach-Object { New-Item -ItemType Directory -Force -Path (Join-Path $root $_) | Out-Null }
```

Expected: all directories listed in “Run Artifact Layout” exist under the fixed run root.

- [ ] **Step 4: Record baseline identity**

Run:

```powershell
$baseline = 'C:\workspace\bbox\outputs\qa\2026-07-13\baseline'
git rev-parse HEAD | Set-Content (Join-Path $baseline 'git-head.txt')
git status --short | Set-Content (Join-Path $baseline 'git-status.txt')
& 'C:\tools\flutter\bin\flutter.bat' --version |
  Set-Content (Join-Path $baseline 'flutter-version.txt')
Select-String -Path pubspec.yaml -Pattern '^version:' |
  Set-Content (Join-Path $baseline 'app-version.txt')
```

Expected: four readable identity files exist and contain current values.

### Task 2: Prove the Automated and Packaging Baseline

**Files:**
- Read: `docs/release-checklist.md`
- Read: `tools/packaging/verify_release_models.ps1`
- Test: all `test/**/*.dart` and `test/tools/*.py`
- Create during execution: `outputs/qa/2026-07-13/baseline/test-output.txt`
- Create during execution: `outputs/qa/2026-07-13/baseline/analyze-output.txt`
- Create during execution: `outputs/qa/2026-07-13/baseline/release-inventory.txt`

**Interfaces:**
- Consumes: Task 1 baseline identity and existing prepared detector runtime.
- Produces: the first valid Release candidate or concrete build/test findings.

- [ ] **Step 1: Run the complete Flutter test suite**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' test 2>&1 |
  Tee-Object 'outputs\qa\2026-07-13\baseline\test-output.txt'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

Expected: exit code `0` and the final Flutter summary reports all tests passed.

- [ ] **Step 2: Run Python detector tests**

Run:

```powershell
& 'C:\workspace\bbox\runtime\python\python.exe' -m unittest discover -s test\tools -p 'test_*.py' -v
```

Expected: exit code `0` with no failures or errors.

- [ ] **Step 3: Run static analysis**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' analyze 2>&1 |
  Tee-Object 'outputs\qa\2026-07-13\baseline\analyze-output.txt'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

Expected: exit code `0` and `No issues found!`.

- [ ] **Step 4: Smoke-test the prepared detector runtime**

Run:

```powershell
& 'C:\workspace\bbox\runtime\python\python.exe' -c "import torch, torchvision, cv2, numpy, ultralytics; print('detector runtime ok'); print(torch.__version__, torchvision.__version__, cv2.__version__, numpy.__version__, ultralytics.__version__)"
```

Expected: exit code `0`, `detector runtime ok`, and all five package versions.

- [ ] **Step 5: Build a fresh Windows Release**

Run:

```powershell
& 'C:\tools\flutter\bin\flutter.bat' build windows --release
```

Expected: exit code `0` and `build\windows\x64\runner\Release\bbox_labeler.exe` has a new write time.

- [ ] **Step 6: Verify the model allow-list and release exclusions**

Run:

```powershell
& 'tools\packaging\verify_release_models.ps1' -ReleaseRoot 'build\windows\x64\runner\Release'
$release = Resolve-Path 'build\windows\x64\runner\Release'
$forbidden = @('train','datasets','outputs','qa_samples','research','FastSAM-s.pt')
$present = $forbidden | Where-Object { Test-Path (Join-Path $release $_) }
if ($present) { throw "Forbidden release entries: $($present -join ', ')" }
```

Expected: no exception and no forbidden entry.

- [ ] **Step 7: Verify mandatory release files and metadata**

Run:

```powershell
$release = Resolve-Path 'build\windows\x64\runner\Release'
$required = @(
  'bbox_labeler.exe',
  'runtime\python\python.exe',
  'tools\detectors\bread_box_worker.py',
  'models\bread_yolov8n_1class_tray_v0_2.pt'
)
$missing = $required | Where-Object { -not (Test-Path (Join-Path $release $_) -PathType Leaf) }
if ($missing) { throw "Missing release files: $($missing -join ', ')" }
$exe = Get-Item (Join-Path $release 'bbox_labeler.exe')
$exe.VersionInfo | Format-List ProductName,ProductVersion,FileVersion,CompanyName
if (($exe.VersionInfo | Out-String) -match 'com\.example') { throw 'Placeholder metadata found' }
```

Expected: no missing file, product/file versions match `pubspec.yaml`, and no `com.example` metadata.

- [ ] **Step 8: Freeze the executable hash and inventory**

Run:

```powershell
$release = Resolve-Path 'build\windows\x64\runner\Release'
Get-FileHash (Join-Path $release 'bbox_labeler.exe') -Algorithm SHA256 |
  Format-List | Set-Content 'outputs\qa\2026-07-13\baseline\exe-sha256.txt'
Get-ChildItem $release -Recurse -File |
  Select-Object FullName,Length,LastWriteTime |
  Format-Table -AutoSize |
  Set-Content 'outputs\qa\2026-07-13\baseline\release-inventory.txt'
```

Expected: the hash and full inventory are present and become the identity for all following evidence.

### Task 3: Prepare Deterministic QA Datasets

**Files:**
- Read: `qa_samples/images/sample_01.jpg`
- Read: `qa_samples/images/한글_샘플_02.png`
- Read: `qa_samples/images/broken.png`
- Create during execution: `outputs/qa/2026-07-13/datasets/**`

**Interfaces:**
- Consumes: repository QA samples without modifying them.
- Produces: small, medium, and large datasets with deterministic filenames and counts.

- [ ] **Step 1: Populate the 10-image small dataset**

Run:

```powershell
$src = 'C:\workspace\bbox\qa_samples\images'
$dst = 'C:\workspace\bbox\outputs\qa\2026-07-13\datasets\small'
1..4 | ForEach-Object { Copy-Item "$src\sample_01.jpg" "$dst\bright sample $($_.ToString('00')).jpg" -Force }
1..4 | ForEach-Object { Copy-Item "$src\한글_샘플_02.png" "$dst\한글 이미지 $($_.ToString('00')).png" -Force }
Copy-Item "$src\broken.png" "$dst\손상 이미지.png" -Force
Copy-Item "$src\sample_01.jpg" "$dst\duplicate-content.jpg" -Force
```

Expected: exactly 10 files, including spaces, Korean names, duplicate content, and one corrupt image.

- [ ] **Step 2: Populate the 500-image medium dataset**

Run:

```powershell
$src = 'C:\workspace\bbox\qa_samples\images\sample_01.jpg'
$dst = 'C:\workspace\bbox\outputs\qa\2026-07-13\datasets\medium'
1..500 | ForEach-Object { Copy-Item $src (Join-Path $dst ("image_{0:D4}.jpg" -f $_)) -Force }
```

Expected: `(Get-ChildItem $dst -File).Count` equals `500`.

- [ ] **Step 3: Populate the 2,000-image large dataset**

Run:

```powershell
$src = 'C:\workspace\bbox\qa_samples\images\sample_01.jpg'
$dst = 'C:\workspace\bbox\outputs\qa\2026-07-13\datasets\large'
1..2000 | ForEach-Object { Copy-Item $src (Join-Path $dst ("image_{0:D5}.jpg" -f $_)) -Force }
```

Expected: `(Get-ChildItem $dst -File).Count` equals `2000`.

- [ ] **Step 4: Record dataset hashes and counts**

Run:

```powershell
$root = 'C:\workspace\bbox\outputs\qa\2026-07-13\datasets'
Get-ChildItem $root -Directory | ForEach-Object {
  [pscustomobject]@{ Name = $_.Name; Count = (Get-ChildItem $_.FullName -File).Count }
} | Format-Table -AutoSize | Set-Content 'outputs\qa\2026-07-13\baseline\dataset-counts.txt'
Get-FileHash 'qa_samples\images\sample_01.jpg','qa_samples\images\한글_샘플_02.png','qa_samples\images\broken.png' |
  Format-Table -AutoSize | Set-Content 'outputs\qa\2026-07-13\baseline\source-sample-hashes.txt'
```

Expected: counts are `10`, `500`, and `2000`; source hashes prove originals were unchanged.

### Task 4: Execute Real-UI Functional and Data-Integrity QA

**Files:**
- Test target: `build/windows/x64/runner/Release/bbox_labeler.exe`
- Data: `outputs/qa/2026-07-13/datasets/small/`
- Create during execution: `outputs/qa/2026-07-13/evidence/gate1-*`
- Create during execution: `outputs/qa/2026-07-13/exports/{normal,incomplete,no-object,restore}/`

**Interfaces:**
- Consumes: frozen Release hash and small dataset.
- Produces: four end-to-end projects, exports, UI evidence, and functional findings.

- [ ] **Step 1: Launch only the frozen Release through Computer Use**

Use Computer Use `list_apps` first. Launch the explicit path
`C:\workspace\bbox\build\windows\x64\runner\Release\bbox_labeler.exe`, select
the returned BBox Labeler window, activate it, and capture a screenshot plus
accessibility tree.

Expected: the selected app path is the Release path, not the installed path, and the visible version/baseline evidence matches Task 2.

- [ ] **Step 2: Run the project lifecycle and import matrix**

Create `QA 2026-07-13 정상 흐름`, import the small folder, then add one image individually. Verify the entered project name in the workbench and home, Korean/spaced filenames, corrupt-image isolation, counts, status labels, and filters. Save, return home, reopen, and compare the UI to persisted state.

Expected: valid images remain usable, corrupt input becomes an isolated error, no source file changes, and all visible counts agree.

- [ ] **Step 3: Run complete canvas editing**

On a valid image, draw one box, select it from overlay and list, move it, resize every edge and corner, zoom, pan, fit, switch to 100%, and repeat one move. Exercise Escape, Delete, undo, and redo. Record the coordinate/area text after every transform.

Expected: selection is bidirectional, all handles work, coordinates stay within the original image, zoom/pan do not mutate stored coordinates, and undo/redo restore one operation at a time.

- [ ] **Step 4: Run label and confirmation rules**

Create a Korean label, attempt the same name twice, change its color/name, assign it, replace it, and try to delete it while in use. Verify confirmation disabled with an unlabeled proposal and enabled when every live box is valid/labeled. Confirm a separate zero-box image with `객체 없음`.

Expected: duplicate/in-use rules are enforced, overlay/list colors and names agree, and zero-box confirmation is deliberate and available.

- [ ] **Step 5: Run detector persistence and failure behavior**

Run automatic boxes on two valid images in sequence. Capture worker output/log evidence, proposal states, UI responsiveness, and cancellation. Exercise one controlled worker-failure test using the existing fake/runtime test boundary rather than corrupting the bundled runtime.

Expected: one worker PID and model initialization serve both images, no source path is sent to the worker, proposals remain unlabeled, cancellation recovers, and failure does not poison later manual work.

- [ ] **Step 6: Run four fixed export scenarios**

Export these projects to their matching fixed directories:

1. `normal`: valid labeled confirmed image.
2. `incomplete`: needs-review image, unlabeled proposal, and error image; acknowledge the accurate warning.
3. `no-object`: confirmed zero-box image included as an empty image.
4. `restore`: edit, wait for autosave, close, relaunch, reopen, continue, and export.

Expected: every flow reaches a JSON file without modifying original images; warning counts match the UI/project.

- [ ] **Step 7: Parse and validate every exported JSON**

Run across the fixed export root:

```powershell
$jsonFiles = @(Get-ChildItem 'outputs\qa\2026-07-13\exports' -Recurse -Filter '*.json' -File)
if ($jsonFiles.Count -lt 4) { throw "Expected at least four COCO JSON files, found $($jsonFiles.Count)" }
foreach ($jsonFile in $jsonFiles) {
  $doc = Get-Content -Raw $jsonFile.FullName | ConvertFrom-Json
  if ($null -eq $doc.images -or $null -eq $doc.annotations -or $null -eq $doc.categories) { throw "Missing COCO top-level key: $($jsonFile.FullName)" }
  $imageIds = @{}; $doc.images | ForEach-Object { if ($imageIds.ContainsKey($_.id)) { throw 'Duplicate image id' }; $imageIds[$_.id] = $_ }
  $categoryIds = @{}; $doc.categories | ForEach-Object { if ($categoryIds.ContainsKey($_.id)) { throw 'Duplicate category id' }; $categoryIds[$_.id] = $_ }
  foreach ($a in $doc.annotations) {
    if (-not $imageIds.ContainsKey($a.image_id)) { throw 'Unknown image_id' }
    if (-not $categoryIds.ContainsKey($a.category_id)) { throw 'Unknown category_id' }
    $x,$y,$w,$h = @($a.bbox)
    $img = $imageIds[$a.image_id]
    if ($x -lt 0 -or $y -lt 0 -or $w -le 0 -or $h -le 0 -or ($x+$w) -gt $img.width -or ($y+$h) -gt $img.height) { throw 'Invalid bbox' }
    if ([double]$a.area -ne ([double]$w * [double]$h)) { throw 'Invalid area' }
    if ($a.iscrowd -ne 0) { throw 'Invalid iscrowd' }
  }
  Write-Host "COCO valid: $($jsonFile.FullName)"
}
```

Expected: at least four JSON files are discovered, every file prints `COCO valid`, proposals/deleted boxes are absent, and repeat export preserves category identity.

### Task 5: Execute Usability, Toss-Principle, and Visual-Design QA

**Files:**
- Read: `lib/ui/app_theme.dart`
- Read: `lib/ui/workbench_copy.dart`
- Read: `lib/ui/project_home_copy.dart`
- Read: `lib/ui/workbench/*.dart`
- Create during execution: `outputs/qa/2026-07-13/evidence/gate2-4-*`
- Create during execution: `docs/qa/2026-07-13-release-qa-report.md`

**Interfaces:**
- Consumes: functional Release and the approved Toss/visual rubric.
- Produces: quantified first-use/repeat-use results and conformance findings.

- [ ] **Step 1: Create the tracked QA report**

Use `apply_patch` to create `docs/qa/2026-07-13-release-qa-report.md` with this initial structure:

```markdown
# BBox Labeler Release QA Report — 2026-07-13

## Baseline Identity

Baseline evidence is stored under `outputs/qa/2026-07-13/baseline/` and is tied to the Release executable SHA-256 recorded there.

## Test Matrix

| Gate | Status | Evidence |
|---|---|---|
| Build and packaging | Passed before UI QA | `outputs/qa/2026-07-13/baseline/` |
| Functional and data integrity | In progress | `outputs/qa/2026-07-13/evidence/` |
| Usability and complexity | In progress | `outputs/qa/2026-07-13/evidence/` |
| Toss UI/UX principles | In progress | `outputs/qa/2026-07-13/evidence/` |
| Visual design | In progress | `outputs/qa/2026-07-13/evidence/` |
| Accessibility, performance, stability | In progress | `outputs/qa/2026-07-13/evidence/` |

## Findings and Corrections

No findings are recorded before the first UI pass.

## COCO Validation

Validation runs after the four fixed export scenarios.

## Final Release Decision

The release decision remains withheld until every approved gate passes on one final executable hash.

## Unverified Conditions

All gates remain unverified until the final acceptance run.
```

Expected: the report exists, accurately states the current phase, and contains no claim that later gates have passed.

- [ ] **Step 2: Run a no-help first-use pass**

From a fresh dedicated project, perform create, import, draw, label, confirm, and export without opening help or tooltips first. Record time to first correct action, total time, click/key count, errors, backtracking, panel crossings, modals, guessed actions, misunderstood terms, and missing feedback.

Expected: each friction point has timestamped evidence and a P0-P3 finding when it materially affects the task.

- [ ] **Step 3: Run a repeat-annotator efficiency pass**

Label ten valid images using the fastest discoverable keyboard/mouse workflow. Record total time, per-image median, unnecessary clicks, pointer travel, confirmation interruptions, and shortcut conflicts.

Expected: every repetitive cost has a concrete count and proposed correction; no vague “feels slow” finding is accepted.

- [ ] **Step 4: Audit feature necessity and UX writing**

For every permanently visible workbench control, answer the five approved necessity questions. Audit every visible string and accessibility label for clarity, concision, active voice, predictable outcome, consistent terminology, neutral tone, and actionable errors.

Expected: each item is retained, moved to progressive disclosure, merged, renamed, or removed based on user-task evidence.

- [ ] **Step 5: Score every Toss principle**

Score one-second understanding, single goal, CTA clarity, cognitive/labor/psychological cost, contextual flow, information priority, writing, user respect, component consistency, and assistive equivalence as conformant/partial/non-conformant.

Expected: each score cites a specific screen and user impact; partial/non-conformant scores become defects and cannot remain at final acceptance.

- [ ] **Step 6: Run the visual-design matrix**

Inspect home, empty workbench, loaded workbench, selected box, many boxes, label management, confirmation, export warning, loading, and error states. Check hierarchy, alignment, spacing scale, Pretendard typography, Korean/English/numeric baselines, component geometry, semantic colors, hover/focus/pressed/disabled states, and overlay readability on bright/dark/busy images.

Expected: every visual issue is tied to a rule and user impact, not taste.

- [ ] **Step 7: Verify representative layout constraints**

Use existing widget-test harnesses to render or pump workbench states at logical 1280x720, 1440x900, and 1920x1080 constraints and at 1.0, 1.25, and 1.5 text/scale equivalents. Add a focused widget test when a state is not covered.

Expected: no overflow exception, clipped required action, accidental horizontal scrolling, overlapping content, or unusably small canvas.

### Task 6: Execute Accessibility, Performance, and Stability QA

**Files:**
- Data: `outputs/qa/2026-07-13/datasets/{small,medium,large}/`
- Create during execution: `outputs/qa/2026-07-13/evidence/gate5-*`
- Update during execution: `docs/qa/2026-07-13-release-qa-report.md`

**Interfaces:**
- Consumes: same frozen/corrected Release and deterministic datasets.
- Produces: keyboard/UIA evidence and comparable timing/resource measurements.

- [ ] **Step 1: Complete the core flow using only the keyboard**

Use Tab/Shift+Tab, Enter/Space, arrows, Escape, Delete, label shortcuts, Ctrl+Enter, and undo/redo. At each screen, capture focused element and UI Automation tree through Computer Use.

Expected: visual/task focus order match, focus is visible, text fields suppress conflicting shortcuts, and every required action is reachable.

- [ ] **Step 2: Audit semantics, names, state, and contrast**

Verify every icon button has a useful accessible name and tooltip; selection, progress, error, and completion are present in UIA; status never relies only on color. Calculate contrast for theme foreground/background pairs from `lib/ui/app_theme.dart`.

Expected: normal text is at least 4.5:1, large text and essential UI boundaries are at least 3:1, and all required semantics are exposed.

- [ ] **Step 3: Measure small, medium, and large projects consistently**

For each dataset, record process start to first screen, import start to first visible item, import completion, image-switch latency over ten switches, detector cancellation latency, autosave interaction blocking, and process working-set before/after a fixed 20-image session.

Use read-only process measurement:

```powershell
Get-Process bbox_labeler | Select-Object Id,StartTime,CPU,WorkingSet64,PrivateMemorySize64,Responding
```

Expected: no `Responding = False`, crash, unbounded working-set growth, or unexplained metric degradation greater than 20% between baseline and corrected build under identical conditions.

- [ ] **Step 4: Run a sustained interaction pass**

Perform at least 100 image switches with repeated zoom, pan, selection, label assignment, undo/redo, and autosave activity while detector work is queued.

Expected: no hang, stale selection, state corruption, lost edit, worker leak, or accumulated visual glitch.

### Task 7: Convert Every Finding into a Concrete Correction Task

**Files:**
- Update: `docs/qa/2026-07-13-release-qa-report.md`
- Modify/Test: exact module/test pair from “Run Artifact Layout” selected only after root-cause evidence identifies ownership.

**Interfaces:**
- Consumes: reproduced findings from Tasks 2-6.
- Produces: zero open P0-P3 findings and one regression-proof correction per root cause.

- [ ] **Step 1: Record and order findings**

Assign IDs `BBOX-QA-001` upward. Record severity, category, exact reproduction, expected/actual result, frequency, user/data impact, evidence path, and affected gates. Order by P0, P1, P2, P3.

Expected: every observed problem is recorded once, with duplicates linked to one root cause.

- [ ] **Step 2: Root-cause the highest-priority open finding**

Reproduce it twice, inspect the persisted state/log/UI tree and the mapped product path, and trace the bad value or decision to its source. Add the identified exact source and test paths to that finding before editing.

Expected: the report explains why the behavior occurs; no correction is attempted from screenshot symptoms alone.

- [ ] **Step 3: Add and prove the regression test**

Write the smallest test in the mapped test file, run the exact test name, and capture the failing output. For native shell behavior that cannot be represented in Flutter tests, write a deterministic manual reproduction entry with before-state evidence.

Expected: automated behavior fails for the expected reason before correction, or the documented native-boundary reproduction is repeatable.

- [ ] **Step 4: Apply the smallest complete correction**

Modify only the exact root-cause file(s). If the issue is a shared design/copy token, enumerate and inspect all call sites before closing it.

Expected: no unrelated refactor or opportunistic feature change.

- [ ] **Step 5: Verify the correction from narrow to broad**

Run the issue test, related test file/directory, complete Flutter test suite, static analysis, Python tests when detector-related, fresh Windows Release build, model/release checks, original Computer Use reproduction, and affected end-to-end scenario.

Expected: all commands exit `0`, the UI evidence shows the corrected result, and no affected flow regresses.

- [ ] **Step 6: Commit the verified correction**

Run:

```powershell
git diff --check
git status --short
git add -u
git add -- docs/qa/2026-07-13-release-qa-report.md
git diff --cached --check
git commit -m "fix: resolve release QA finding"
```

Expected: only the inspected tracked source/test changes and QA report are staged, the staged diff passes whitespace validation, and one intentional correction batch is committed. If root-cause work requires a new source or test file, update this plan with that exact path before creating or staging it.

- [ ] **Step 7: Repeat until the open count is zero**

Return to Step 2 for the next open item. After the final item, query the report and confirm there are no `Open`, `Reproduced`, or `Partially verified` P0-P3 entries.

Expected: zero open P0-P3 findings before Task 8.

### Task 8: Run Final Release Acceptance and Publish the QA Report

**Files:**
- Create/Finalize: `docs/qa/2026-07-13-release-qa-report.md`
- Read: `docs/release-checklist.md`
- Read: `docs/superpowers/specs/2026-07-10-comprehensive-release-qa-design.md`
- Evidence: `outputs/qa/2026-07-13/**`

**Interfaces:**
- Consumes: corrected Git HEAD with zero open findings.
- Produces: one final executable hash and an evidence-backed release decision.

- [ ] **Step 1: Re-run all automated gates from a clean status**

Run:

```powershell
git status --short
& 'C:\tools\flutter\bin\flutter.bat' test
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& 'C:\tools\flutter\bin\flutter.bat' analyze
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& 'C:\workspace\bbox\runtime\python\python.exe' -m unittest discover -s test\tools -p 'test_*.py' -v
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& 'C:\tools\flutter\bin\flutter.bat' build windows --release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& 'tools\packaging\verify_release_models.ps1' -ReleaseRoot 'build\windows\x64\runner\Release'
```

Expected: clean intentional status and every command exits `0`.

- [ ] **Step 2: Record the final baseline identity**

Record Git HEAD, app version, Flutter version, Release write time, executable metadata, SHA-256, and inventory alongside the original baseline. Mark all earlier UI evidence as superseded unless it is explicitly linked as before-fix evidence.

Expected: every final claim points to the same final SHA-256.

- [ ] **Step 3: Run the four mandatory scenarios twice consecutively**

On the final Release, repeat normal, incomplete, no-object, and restore scenarios twice. Repeat independent COCO validation after each export.

Expected: eight scenario runs and eight JSON validations pass without intermittent behavior.

- [ ] **Step 4: Re-run the detector, Toss, visual, accessibility, and large-project acceptance checks**

Confirm two-image worker reuse/single load; every Toss score is conformant; visual checklist has no unresolved entry; keyboard-only core flow passes; UIA semantics remain complete; large project has no hang/crash/leak or unexplained >20% regression.

Expected: every approved design criterion has fresh final-build evidence.

- [ ] **Step 5: Finalize the report**

The report must contain baseline identity, environment, test matrix, all findings and commits, before/after evidence, COCO validation, functional/usability/Toss/visual/accessibility/performance assessments, final hash, and an `Unverified conditions` section containing exactly `None`.

Expected: no unfinished marker, missing evidence link, contradictory status, or unverified condition.

- [ ] **Step 6: Commit the final report**

Run:

```powershell
git diff --check
git add -- docs/qa/2026-07-13-release-qa-report.md
git commit -m "docs: record final BBox Labeler release QA"
git status --short
```

Expected: final report commit succeeds and worktree contains no unintended changes.

- [ ] **Step 7: Make the release decision**

Declare `Ready` only if automated checks pass, the four scenarios pass twice, COCO validation passes, detector persistence passes, open P0-P3 count is zero, Toss non-conformance count is zero, visual/accessibility findings are zero, performance acceptance passes, and `Unverified conditions` is `None`.

Expected: the final user message cites the final commit, executable path/hash, verification commands, defect count, report path, and release decision.
