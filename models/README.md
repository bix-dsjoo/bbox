# Runtime Models

Place local automatic-box runtime model files here before building a release.

The only product runtime model is:

- `bread_yolov8n_1class_tray_v0_2.pt`: 1-class bread detector tuned for tray/paper operating photos.

Model weights are local runtime assets and are intentionally ignored by source
control. Classifier, fallback, and verifier weights may remain in a development
workspace for research, but they are not product runtime or release assets.
