# Runtime Models

`bread_pipeline_manifest.json` is the schema-v1 product contract. A release must
package that manifest and the exact sibling files named and hashed by it:

- `bread_detector_<candidate>_v2.pt`: the fast A/B winner trained on all real
  detector data after one-fold screening and five-fold OOF validation.
- `bread_classifier_yolov8n_cls_v1_<sha256>.pt`: content-addressed 20-class
  classifier trained for 21 fixed epochs on all 3,230 single-product images and
  all 510 real mixed-scene GT crops. The manifest is switched only after the new
  sibling file and prospective contract pass validation. Its precision and
  coverage remain five-fold OOF claims, not final-weight in-sample metrics.

The approved verifier is `kind: none`, so no verifier weight belongs in the
release. Synthetic data is omitted because there are no approved backgrounds;
that reason is recorded in the ignored selection report, not as a manifest
model.

`bread_yolov8n_1class_tray_v0_2.pt` is deprecated. It remains available only
as the Candidate A2 training seed and historical provenance until the v2
manifest handoff is complete. Packaging must never include it once the v2
detector has been published.

Model weights are local runtime assets and intentionally ignored by source
control. Run
`python tools/detectors/bread_pipeline_manifest.py models/bread_pipeline_manifest.json`
before packaging to recompute local hashes and validate labels, thresholds,
quality settings, and verifier absence. The selection workflow also writes its
handoff audit beside `selection_report.json`.
