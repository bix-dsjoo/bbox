# Portable Project Final Fixes Report

Date: 2026-07-15

Base: `c22e067282e4e11939398b780dadc072bcc25894`

Result: DONE

## Implemented findings

1. Portable snapshot imports now validate the raw JSON boundary before tolerant model decoding, reject unknown enum strings and malformed required types, and normalize read/decode/schema failures as actionable `InvalidProjectSnapshotException` values. Decoded projects are then checked for normalized duplicate label names, duplicate shortcuts, positive image dimensions, finite positive in-bounds boxes, box status/label/source consistency, duplicate candidate IDs, all label references, and finite `[0, 1]` candidate scores/confidences. Invalid imports are proven not to create a library directory or index entry.
2. Every `ProjectLibrary` read/mutation is coordinated by one instance queue. Public methods call unlocked helpers internally, so composite create/import/rename/delete/refresh/rebuild flows do not self-deadlock. Index replacement remains atomic through flushed temp files, backup promotion, rollback, and artifact cleanup.
3. Source relinking now builds hash and normalized `(filename, width, height)` indexes. Preferred relative paths stay authoritative when valid, while bucket ownership detects shared-candidate ambiguity without expanding collision buckets for every image. Candidate paths use Windows-only case folding through an injectable path-key seam.
4. Non-positive `maxConcurrentCandidateLoads` is rejected with `ArgumentError.value` on every public runtime path and inside the bounded mapper. The const constructor remains available.
5. Relink project/missing-image/original-path preflight runs before `_sourceRelinkInFlight` ownership, so a preflight failure cannot poison subsequent relinks.
6. The approved Korean review heading and project snapshot save-failure copy are exact and covered by direct tests.
7. Snapshot import exposes `ProjectActivity.importing`; the project home disables create, import, open, rename, and delete entry points while that activity is busy. Existing autosave-before-import ordering remains covered.

## RED evidence

- Snapshot table tests initially produced 25 expected failures: unvalidated normalized duplicates/dimensions/geometry/status rules/candidate metadata, unknown enums falling back silently, raw casts leaking `TypeError`, unsupported schemas escaping normalization, and non-finite JSON numbers being accepted.
- Project-library concurrency tests initially failed to compile because no queue/barrier seam existed. The tests deliberately held create/import operations while scheduling concurrent import/rename/delete work.
- Relink tests initially failed to compile because indexed lookup instrumentation, platform path-key injection, and public runtime validation did not exist. After the first indexed implementation, the existing unresolved-candidate test correctly caught a zero-candidate bucket being classified as ambiguous; the bucket rule was corrected before proceeding.
- Controller/UI/copy RED produced five expected failures: snapshot import stayed idle, no-project relink poisoned ownership, project-home actions remained enabled, and both approved strings differed.

## GREEN evidence

- Snapshot + library focused: 46 tests passed.
- Relink + controller focused: 60 tests passed.
- Controller/library/home/copy focused: 73 tests passed.
- Complete portable/relink/controller/candidate/canvas focused set: 246 tests passed.
- Full Flutter suite: 507 tests passed.
- `flutter analyze`: no issues found.
- Targeted Dart format check: 13 files, 0 changes.
- `git diff --check c22e067282e4e11939398b780dadc072bcc25894..HEAD`: clean.
- Collision-heavy fixture: 600 candidates loaded once each and exactly 600 image bucket lookups; all 600 shared matches remained conservatively ambiguous.
- Repository-wide format check examined 98 files and identified only the protected pre-existing `test/packaging/installer_script_test.dart` formatting difference.

## Commits

- `38485d0 fix: harden portable project imports`
- `36c4c2d fix: index portable source relinking`
- `ee485c4 fix: guard portable project workflows`
- `253b45b style: satisfy portable workflow analysis`

## Preserved unrelated work

The following six pre-existing dirty files were never staged or modified by these fixes:

- `models/bread_pipeline_manifest.json`
- `test/packaging/installer_script_test.dart`
- `test/tools/test_bread_box_worker.py`
- `tools/detectors/bread_box_worker.py`
- `tools/packaging/build_windows_installer.ps1`
- `windows/CMakeLists.txt`

## Remaining limitations

- Project-library serialization is intentionally per `ProjectLibrary` instance. It does not attempt cross-process locking, which was outside the requested single-instance queue scope.
- The repository-wide formatter remains non-zero solely because the protected unrelated installer test is not formatted. Targeted feature files and static analysis are clean.
