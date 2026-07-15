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

## Re-review Fixes

### Implemented

- Candidate ownership is now normalized across hash and legacy filename/dimension indexes. After provisional unique matches from every key type, normalized candidate paths are grouped by owner image; a path with multiple owners makes every owner ambiguous and removes every provisional match.
- Preferred-path collisions are aggregated by bucket. Preferred owners and general owners for a key are processed once per collision bucket, avoiding repeated expansion of the same general-owner set for each preferred image.
- Snapshot reading now performs one text read, validates the resulting in-memory JSON map, and decodes/migrates that same map through `ProjectStore.decodeJson`. Ordinary `ProjectStore.load` uses the same tolerant in-memory decode helper.
- Create/import/rename/delete library composites now roll back on index-write failure. New project directories are removed, rename restores the exact original JSON bytes, and delete uses a checked internal tombstone rename with restoration before index commit failure. The serialized queue recovers after every injected failure.

### RED evidence

- A single candidate that was unique under one hash key and one legacy signature key was assigned to both images. The mixed regression observed two matches where both image IDs had to be ambiguous.
- With 120 preferred and 120 general owners in one collision signature, instrumentation observed 14,520 ownership work units, exceeding the near-linear bound of 2,880.
- The snapshot single-read test initially failed to compile because no injected reader/shared in-memory decoder existed. Its disk payload intentionally contains an unknown post-validation box enum while the one injected read returns valid JSON.
- Four injected index-write rollback tests initially failed to compile because no index-write seam existed. They cover create, import, rename, and delete, including a successful next operation on the same queue after each failure.

### GREEN evidence

- Relink focused suite: 18 tests passed. The mixed hash/signature candidate now makes both owners ambiguous.
- Preferred/general collision fixture stays within 2,880 instrumented ownership units for 240 images, with all owners conservatively ambiguous.
- Snapshot/store/schema migration focused set: 39 tests passed; the injected reader is called exactly once and the valid in-memory labeled box is decoded despite the different disk payload.
- Library focused suite: 16 tests passed, including exact JSON restoration, tombstone cleanup, index/directory state, and queue-tail recovery.
- Combined affected snapshot/library/relink/controller/integration set: 136 tests passed.
- Fresh full Flutter suite after re-review commits: 514 tests passed.
- `flutter analyze`: no issues found.

### Re-review commits

- `e9027d0 fix: close portable relink ownership gaps`
- `e0ce6a4 fix: roll back failed library mutations`

### Re-review limitations

- The existing per-instance queue and cross-process limitation remain unchanged.
- Repository-wide formatting still differs only in the protected unrelated installer test; no protected file was staged or modified by the re-review fixes.

## Closure Fixes

### Implemented

- A successful temp-to-live index rename is now the index write commit point. Backup deletion and stale-backup cleanup occur after commit as best-effort work, so cleanup failure cannot make create, import, rename, or delete report failure after the new index is already live. Later queued writes tolerate and remove stale uniquely named backups.
- Tombstone deletion is post-commit best-effort work. Rebuild skips every `.deleting-*` directory and retries cleanup without indexing it, preventing a logically deleted project from being resurrected when physical cleanup fails.
- Library entries now share an exact ownership validator requiring normalized `<projectsRoot>/<entry.id>/project.bbox.json`. Open, rename, refresh, and delete reject cross-ID paths before reading or mutating either project directory; create/import and rebuild use the same canonical-path rule.
- Default source candidate metadata now reads one `Uint8List`, decodes dimensions from those bytes, and computes SHA-256 with `sha256.convert(bytes)`. The injected byte-reader regression proves one read and byte-consistent dimensions/hash while preserving bounded candidate concurrency.

### RED evidence

- The closure regression set initially failed to compile because the post-promotion backup-delete, tombstone-delete, and candidate-byte-reader fault seams did not exist.
- The new library cases cover all four index-mutating workflows, keep backup deletion failing for the entire first committed operation, and require the next operation on the same queue to remove the stale backup successfully.
- The tombstone case injects recursive cleanup failure, then requires delete success, an empty rebuilt/listed index, a retained non-indexed tombstone, and a successful next create.
- The cross-ID case corrupts one entry to point at another entry's exact in-root file and requires open, rename, refresh, and delete to throw without changing either project JSON, directory, or the corrupt index bytes.
- The metadata case supplies valid PNG bytes for a nonexistent candidate path and requires one injected read plus a successful dimensions/hash match, which rules out a second disk stream.

### GREEN evidence

- Closure library + relink focused set: 41 tests passed.
- Affected project/controller/home/transfer/integration set: 153 tests passed.
- Fresh full Flutter suite: 521 tests passed.
- `flutter analyze`: no issues found.
- Targeted Dart format check: 4 files, 0 changes.
- `git diff --check`: clean.

### Closure commits

- `0eb94be fix: finalize portable library durability`

### Closure limitations

- Serialization remains intentionally per `ProjectLibrary` instance; cross-process locking remains outside scope.
- Repository-wide formatting still differs only in the protected unrelated installer test. All closure files are formatted, and none of the six protected dirty files was staged or modified.

## Post-commit Probe Fix

### Implemented

- Direct backup existence checks, backup-root existence checks, stale-backup directory stream creation/enumeration, and tombstone existence checks now execute entirely inside their best-effort cleanup boundaries.
- Delete no longer performs a tombstone `exists` probe outside cleanup. Once the index commit succeeds, it unconditionally hands the tombstone to the guarded helper, so probe or deletion failures cannot reverse logical success.
- Injectable file-exists, directory-exists, and directory-list seams cover each post-commit probe without changing the pre-commit rollback boundary.

### RED evidence

- Five new regressions initially failed to compile because the backup existence, backup-root existence/listing, and tombstone existence seams did not exist.
- Create injects a direct backup existence failure; import and delete inject the second backup-root existence call after promotion; rename injects the second stale-backup enumeration after promotion; tombstone delete injects an existence-probe failure after the delete index commit.
- Every case requires a successful operation result, matching JSON/index/directory state, and a successful next operation on the same serialized queue. The tombstone case also requires rebuild/list to keep the failed-cleanup directory excluded.

### GREEN evidence

- Project-library focused suite: 27 tests passed, including all existing pre-commit create/import/rename/delete rollback cases.
- Affected project/controller/home/transfer/integration set: 158 tests passed.
- Fresh full Flutter suite: 526 tests passed.
- `flutter analyze`: no issues found.
- Targeted Dart format check: 2 files, 0 changes.
- `git diff --check`: clean.

### Post-commit probe commit

- `b0d6d39 fix: contain post-commit probe failures`

### Result

DONE. No post-commit backup or tombstone existence/enumeration probe can propagate through the guarded cleanup paths. The six protected pre-existing dirty files remain unstaged and unmodified by this fix.
