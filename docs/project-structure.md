# Project Structure

This project is a Flutter Windows desktop app for local COCO bounding-box labeling.

## Product Source

- `lib/annotation/`: annotation domain models, bbox rules, label defaults, and label migrations.
- `lib/project/`: project persistence and local project library indexing.
- `lib/image_import/`: supported image scanning and image metadata extraction.
- `lib/detector/`: detector contracts, the persistent bread worker client and
  automatic-box service, plus non-sidecar algorithmic detectors.
- `lib/export/`: COCO JSON export and export validation.
- `lib/viewer/`: viewport coordinate transforms for original-image to screen-space mapping.
- `lib/ui/`: Flutter UI, app controller, workbench, dialogs, theme, and UI copy.
- `assets/`: app branding and bundled font assets used by the Flutter app.
- `windows/`: Flutter Windows runner and native Windows app metadata.

## Tests

- `test/annotation/`: bbox, label, and annotation rule tests.
- `test/project/`: project save/load and project library tests.
- `test/image_import/`: scanner tests for supported image inputs.
- `test/detector/`: detector contract and detector implementation tests.
- `test/export/`: COCO export tests.
- `test/viewer/`: viewport transform tests.
- `test/ui/`: widget and controller tests.
- `test/integration/`: MVP workflow tests.
- `test/packaging/`: installer and version consistency tests.

## Tooling And Packaging

- `tools/detectors/`: the coordinate-only persistent bread worker used by
  automatic-box proposals.
- `tools/packaging/`: Windows release and detector runtime packaging helpers.
- `models/`: the tray detector model used by the product runtime; research
  weights are not copied into releases.
- `installer/`: Inno Setup script and installer images.
- `docs/`: release notes, design specs, implementation plans, and project documentation.

## Local Data And Generated Artifacts

These folders can exist in a developer workspace, but they are not normal product source:

- `build/`: Flutter, installer, and local build outputs.
- `dist/`: generated installer artifacts.
- `runtime/python/`: generated bundled Python detector runtime.
- `datasets/`: local development images.
- `train/`: local training or sample images.
- `qa_samples/`: local QA image samples.
- `outputs/`: generated analysis, overlay, or export outputs.

The repository `.gitignore` excludes these large or generated folders. Do not depend on them for normal source builds unless a test or release procedure explicitly says so.
