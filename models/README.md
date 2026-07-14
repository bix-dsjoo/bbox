# Runtime Models

`bread_pipeline_manifest.json` is the schema-v1 product contract. A release must
package that manifest and the exact sibling files named and hashed by it:

- `bread_yolov8n_1class_tray_v0_2.pt`: retained one-class bread detector. Both
  retrained candidates failed only the approved median-IoU adoption gate.
- `bread_classifier_yolov8n_cls_v1_<sha256>.pt`: content-addressed 20-class
  classifier trained for 21 fixed epochs on all 3,230 single-product images and
  all 510 real mixed-scene GT crops. The manifest is switched only after the new
  sibling file and prospective contract pass validation. Its precision and
  coverage remain five-fold OOF claims, not final-weight in-sample metrics.

The approved verifier is `kind: none`, so no verifier weight belongs in the
release. Synthetic data is omitted because there are no approved backgrounds;
that reason is recorded in the ignored selection report, not as a manifest
model.

Model weights are local runtime assets and intentionally ignored by source
control. Run `python -m tools.bread_training.run_selection audit-handoff` with
the manifest and an output path before packaging to recompute local hashes and
validate labels, thresholds, quality settings, and verifier absence.
