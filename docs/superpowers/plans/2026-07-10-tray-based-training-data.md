# Tray-Based Training Data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the dataset tooling needed to train a bread detector for the real wooden-tray operating environment, with empty-tray negatives, AI/real tray synthetic backgrounds, and held-out tray evaluation.

**Architecture:** Extend the existing Python experiment scripts instead of adding product UI. Keep generated images under ignored `datasets/` and `outputs/` folders, keep runtime model promotion manual, and add pure metric helpers so evaluation can be tested without requiring YOLO inference. The Flutter app behavior and COCO export remain unchanged.

**Tech Stack:** Python 3.12 via `runtime/python/python.exe`, OpenCV `cv2`, NumPy, standard-library `unittest`, existing Ultralytics detector runtime for optional smoke tests.

## Global Constraints

- Detector target remains one class: `0: bread`.
- Empty tray images are negative examples with empty YOLO label files, not a new `tray` class.
- AI-generated empty tray images may be used as supplemental negatives and supplemental synthetic background templates.
- Real empty tray photos should remain the preferred template source once enough are collected.
- `E0701.jpg` and `M0711.jpg` stay held out at first and must not be mixed into training until a separate fixed evaluation set exists.
- Generated datasets live under `datasets/` and generated training outputs live under `outputs/`.
- Runtime model files copied into `models/` only after manual evaluation passes.
- Do not change Flutter UI, project persistence, COCO export, or automatic-label acceptance behavior.
- Use `runtime/python/python.exe` for Python verification commands in this workspace.
- This workspace may not be a git repository; run commit steps only after `git rev-parse --is-inside-work-tree` succeeds.

---

## File Structure

- Modify `tools/experiments/build_bread_yolo_synth.py`: add reusable dataset helpers, negative image support, and real tray template background support.
- Create `tools/experiments/prepare_tray_eval_dataset.py`: copy held-out operating images into an evaluation dataset shell and write labeling instructions.
- Create `tools/experiments/evaluate_tray_detector.py`: pure evaluation helpers plus a CLI for comparing detector predictions against YOLO labels.
- Create `test/tools/test_build_bread_yolo_synth.py`: Python unit tests for synthetic dataset helper behavior.
- Create `test/tools/test_evaluate_tray_detector.py`: Python unit tests for tray evaluation metrics.
- Create `docs/training/tray-data-workflow.md`: operator-facing commands for collecting negatives, generating tray synthetic data, preparing eval data, training, and promotion.
- Use `datasets/bread_tray_negatives_v0_1/generated/` for AI-generated empty tray negatives.
- Use `datasets/bread_tray_templates_v0_1/generated/` and `datasets/bread_tray_templates_v0_1/real/` as tray template pools.

---

### Task 1: Add Testable Dataset Helpers

**Files:**
- Modify: `tools/experiments/build_bread_yolo_synth.py`
- Create: `test/tools/test_build_bread_yolo_synth.py`

**Interfaces:**
- Produces: `SUPPORTED_IMAGE_SUFFIXES: set[str]`
- Produces: `supported_image_paths(directory: Path) -> list[Path]`
- Produces: `write_dataset_yaml(output: Path) -> None`
- Produces: `resize_to_square(image: np.ndarray, size: int) -> np.ndarray`
- Produces: `write_empty_yolo_label(path: Path) -> None`
- Consumed by later tasks: negative image generation and tray template generation.

- [ ] **Step 1: Write failing helper tests**

Create `test/tools/test_build_bread_yolo_synth.py`:

```python
import importlib.util
import tempfile
import unittest
from pathlib import Path

import cv2
import numpy as np


MODULE_PATH = (
    Path(__file__).resolve().parents[2]
    / "tools"
    / "experiments"
    / "build_bread_yolo_synth.py"
)
SPEC = importlib.util.spec_from_file_location("build_bread_yolo_synth", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
build_synth = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build_synth)


class BuildBreadYoloSynthHelperTest(unittest.TestCase):
    def test_supported_image_paths_returns_sorted_supported_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "b.PNG").write_bytes(b"x")
            (root / "a.jpg").write_bytes(b"x")
            (root / "notes.txt").write_text("skip", encoding="utf-8")
            (root / "nested").mkdir()
            (root / "nested" / "c.webp").write_bytes(b"x")

            paths = build_synth.supported_image_paths(root)

            self.assertEqual([path.name for path in paths], ["a.jpg", "b.PNG", "c.webp"])

    def test_write_dataset_yaml_uses_one_class_bread_layout(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp)

            build_synth.write_dataset_yaml(output)

            self.assertEqual(
                (output / "dataset.yaml").read_text(encoding="utf-8"),
                "\n".join(
                    [
                        f"path: {output.resolve().as_posix()}",
                        "train: images/train",
                        "val: images/val",
                        "names:",
                        "  0: bread",
                        "",
                    ]
                ),
            )

    def test_resize_to_square_preserves_content_inside_requested_size(self):
        image = np.zeros((10, 20, 3), dtype=np.uint8)
        image[:, :] = (10, 20, 30)

        resized = build_synth.resize_to_square(image, 32)

        self.assertEqual(resized.shape, (32, 32, 3))
        self.assertGreater(int(resized.mean()), 0)

    def test_write_empty_yolo_label_creates_empty_file(self):
        with tempfile.TemporaryDirectory() as temp:
            label_path = Path(temp) / "empty.txt"

            build_synth.write_empty_yolo_label(label_path)

            self.assertTrue(label_path.exists())
            self.assertEqual(label_path.read_text(encoding="utf-8"), "")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run helper tests to verify they fail**

Run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.test_build_bread_yolo_synth -v
```

Expected: FAIL with missing attributes such as `supported_image_paths`.

- [ ] **Step 3: Implement dataset helpers**

In `tools/experiments/build_bread_yolo_synth.py`, add these imports and helpers near the top after imports:

```python
SUPPORTED_IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def supported_image_paths(directory):
    if directory is None or not directory.exists():
        return []
    return sorted(
        path
        for path in directory.rglob("*")
        if path.is_file() and path.suffix.lower() in SUPPORTED_IMAGE_SUFFIXES
    )


def resize_to_square(image, size):
    height, width = image.shape[:2]
    if height <= 0 or width <= 0:
        raise ValueError("image must have positive dimensions")
    scale = size / max(height, width)
    new_width = max(1, int(round(width * scale)))
    new_height = max(1, int(round(height * scale)))
    resized = cv2.resize(image, (new_width, new_height), interpolation=cv2.INTER_AREA)
    canvas = np.zeros((size, size, 3), dtype=np.uint8)
    x = (size - new_width) // 2
    y = (size - new_height) // 2
    canvas[y : y + new_height, x : x + new_width] = resized
    return canvas


def write_empty_yolo_label(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("", encoding="utf-8")


def write_dataset_yaml(output):
    yaml_path = output / "dataset.yaml"
    yaml_path.write_text(
        "\n".join(
            [
                f"path: {output.resolve().as_posix()}",
                "train: images/train",
                "val: images/val",
                "names:",
                "  0: bread",
                "",
            ]
        ),
        encoding="utf-8",
    )
    return yaml_path
```

Replace the inline `dataset.yaml` writing block in `build_dataset` with:

```python
    yaml_path = write_dataset_yaml(args.output)
    print(f"cutouts={len(cutouts)}")
    print(yaml_path.resolve())
```

- [ ] **Step 4: Run helper tests to verify they pass**

Run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.test_build_bread_yolo_synth -v
```

Expected: PASS for 4 tests.

- [ ] **Step 5: Commit**

Run:

```powershell
if ((git rev-parse --is-inside-work-tree) -eq 'true') {
  git add tools/experiments/build_bread_yolo_synth.py test/tools/test_build_bread_yolo_synth.py
  git commit -m "test: cover bread dataset helper utilities"
}
```

Expected: Commit is created when the workspace is a git repository; otherwise the command may be skipped by the shell condition.

---

### Task 2: Add Empty-Tray Negative Image Support

**Files:**
- Modify: `tools/experiments/build_bread_yolo_synth.py`
- Modify: `test/tools/test_build_bread_yolo_synth.py`

**Interfaces:**
- Consumes: `supported_image_paths(directory: Path) -> list[Path]`
- Consumes: `resize_to_square(image: np.ndarray, size: int) -> np.ndarray`
- Consumes: `write_empty_yolo_label(path: Path) -> None`
- Produces: `add_negative_images(output: Path, split: str, source_paths: list[Path], count: int, size: int, rng: random.Random, prefix: str = "negative") -> int`
- Produces CLI args: `--negative-image-dir`, `--negative-train`, `--negative-val`

- [ ] **Step 1: Write failing negative image tests**

Append to `BuildBreadYoloSynthHelperTest` in `test/tools/test_build_bread_yolo_synth.py`:

```python
    def test_add_negative_images_writes_images_and_empty_labels(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source_dir = root / "source"
            source_dir.mkdir()
            image = np.zeros((12, 20, 3), dtype=np.uint8)
            image[:, :] = (40, 45, 50)
            cv2.imencode(".jpg", image)[1].tofile(str(source_dir / "empty_tray.jpg"))
            output = root / "dataset"
            rng = build_synth.random.Random(123)

            written = build_synth.add_negative_images(
                output,
                "train",
                [source_dir / "empty_tray.jpg"],
                count=2,
                size=32,
                rng=rng,
            )

            self.assertEqual(written, 2)
            self.assertTrue((output / "images" / "train" / "negative_00000.jpg").exists())
            self.assertTrue((output / "images" / "train" / "negative_00001.jpg").exists())
            self.assertEqual(
                (output / "labels" / "train" / "negative_00000.txt").read_text(
                    encoding="utf-8"
                ),
                "",
            )
            self.assertEqual(
                (output / "labels" / "train" / "negative_00001.txt").read_text(
                    encoding="utf-8"
                ),
                "",
            )

    def test_add_negative_images_returns_zero_when_no_sources_exist(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "dataset"
            rng = build_synth.random.Random(123)

            written = build_synth.add_negative_images(
                output,
                "val",
                [],
                count=3,
                size=32,
                rng=rng,
            )

            self.assertEqual(written, 0)
            self.assertFalse((output / "images").exists())
```

- [ ] **Step 2: Run tests to verify negative support fails**

Run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.test_build_bread_yolo_synth -v
```

Expected: FAIL with missing `add_negative_images`.

- [ ] **Step 3: Implement negative image writer**

Add this function to `tools/experiments/build_bread_yolo_synth.py` after `write_empty_yolo_label`:

```python
def add_negative_images(
    output,
    split,
    source_paths,
    count,
    size,
    rng,
    prefix="negative",
):
    if count <= 0 or not source_paths:
        return 0

    image_dir = output / "images" / split
    label_dir = output / "labels" / split
    image_dir.mkdir(parents=True, exist_ok=True)
    label_dir.mkdir(parents=True, exist_ok=True)

    written = 0
    for index in range(count):
        source_path = rng.choice(source_paths)
        image = decode_image(source_path)
        if image is None:
            continue
        canvas = resize_to_square(image, size)
        stem = f"{prefix}_{index:05d}"
        image_path = image_dir / f"{stem}.jpg"
        label_path = label_dir / f"{stem}.txt"
        cv2.imencode(".jpg", canvas, [int(cv2.IMWRITE_JPEG_QUALITY), 92])[1].tofile(
            str(image_path)
        )
        write_empty_yolo_label(label_path)
        written += 1
    return written
```

Add CLI args in `main()`:

```python
    parser.add_argument("--negative-image-dir", type=Path)
    parser.add_argument("--negative-train", type=int, default=0)
    parser.add_argument("--negative-val", type=int, default=0)
```

In `build_dataset(args)`, after the synthetic loops and before writing `dataset.yaml`, add:

```python
    negative_paths = supported_image_paths(args.negative_image_dir)
    train_negatives = add_negative_images(
        args.output,
        "train",
        negative_paths,
        args.negative_train,
        args.size,
        rng,
    )
    val_negatives = add_negative_images(
        args.output,
        "val",
        negative_paths,
        args.negative_val,
        args.size,
        rng,
    )
```

Change the print line to:

```python
    print(
        f"cutouts={len(cutouts)} train_negatives={train_negatives} "
        f"val_negatives={val_negatives}"
    )
```

- [ ] **Step 4: Run tests to verify negative support passes**

Run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.test_build_bread_yolo_synth -v
```

Expected: PASS for 6 tests.

- [ ] **Step 5: Commit**

Run:

```powershell
if ((git rev-parse --is-inside-work-tree) -eq 'true') {
  git add tools/experiments/build_bread_yolo_synth.py test/tools/test_build_bread_yolo_synth.py
  git commit -m "feat: add empty tray negative dataset support"
}
```

Expected: Commit is created when the workspace is a git repository.

---

### Task 3: Add Real Tray Template Synthetic Backgrounds

**Files:**
- Modify: `tools/experiments/build_bread_yolo_synth.py`
- Modify: `test/tools/test_build_bread_yolo_synth.py`

**Interfaces:**
- Consumes: `supported_image_paths(directory: Path) -> list[Path]`
- Consumes: `resize_to_square(image: np.ndarray, size: int) -> np.ndarray`
- Produces: `load_template_backgrounds(directory: Path | None, size: int) -> list[np.ndarray]`
- Produces: `make_template_background(template: np.ndarray, rng: random.Random) -> np.ndarray`
- Produces: `make_canvas(args: argparse.Namespace, rng: random.Random, templates: list[np.ndarray]) -> np.ndarray`
- Produces CLI args: `--tray-template-dir`, `--template-probability`, `--placement-margin-ratio`

- [ ] **Step 1: Write failing tray template tests**

Append to `BuildBreadYoloSynthHelperTest` in `test/tools/test_build_bread_yolo_synth.py`:

```python
    def test_load_template_backgrounds_reads_supported_images_as_square_canvases(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            image = np.zeros((12, 20, 3), dtype=np.uint8)
            image[:, :] = (60, 80, 100)
            cv2.imencode(".jpg", image)[1].tofile(str(root / "tray.jpg"))

            templates = build_synth.load_template_backgrounds(root, size=32)

            self.assertEqual(len(templates), 1)
            self.assertEqual(templates[0].shape, (32, 32, 3))
            self.assertGreater(int(templates[0].mean()), 0)

    def test_make_canvas_uses_template_when_probability_is_one(self):
        template = np.zeros((32, 32, 3), dtype=np.uint8)
        template[:, :] = (80, 90, 100)
        args = type(
            "Args",
            (),
            {
                "size": 32,
                "template_probability": 1.0,
            },
        )()
        rng = build_synth.random.Random(123)

        canvas = build_synth.make_canvas(args, rng, [template])

        self.assertEqual(canvas.shape, (32, 32, 3))
        self.assertGreater(int(canvas.mean()), 70)
```

- [ ] **Step 2: Run tests to verify tray template support fails**

Run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.test_build_bread_yolo_synth -v
```

Expected: FAIL with missing `load_template_backgrounds` or `make_canvas`.

- [ ] **Step 3: Implement template background support**

Add these functions after `make_background`:

```python
def load_template_backgrounds(directory, size):
    templates = []
    for path in supported_image_paths(directory):
        image = decode_image(path)
        if image is None:
            continue
        templates.append(resize_to_square(image, size))
    return templates


def make_template_background(template, rng):
    canvas = template.copy()
    alpha = rng.uniform(0.88, 1.12)
    beta = rng.randint(-10, 10)
    canvas = np.clip(canvas.astype(np.float32) * alpha + beta, 0, 255).astype(np.uint8)
    if rng.random() < 0.25:
        canvas = cv2.GaussianBlur(canvas, (3, 3), 0)
    jitter = np.random.default_rng(rng.randint(0, 2**31 - 1)).normal(
        0,
        2,
        canvas.shape,
    )
    return np.clip(canvas.astype(np.float32) + jitter, 0, 255).astype(np.uint8)


def make_canvas(args, rng, templates):
    if templates and rng.random() < args.template_probability:
        return make_template_background(rng.choice(templates), rng)
    return make_background(args.size, rng)
```

Add CLI args in `main()`:

```python
    parser.add_argument("--tray-template-dir", type=Path)
    parser.add_argument("--template-probability", type=float, default=0.75)
    parser.add_argument("--placement-margin-ratio", type=float, default=0.12)
```

At the start of `build_dataset(args)`, after cutout extraction succeeds, add:

```python
    templates = load_template_backgrounds(args.tray_template_dir, args.size)
```

Replace:

```python
            canvas = make_background(args.size, rng)
```

with:

```python
            canvas = make_canvas(args, rng, templates)
```

Modify `paste_cutout` signature:

```python
def paste_cutout(canvas, cutout, alpha, object_bbox, rng, placement_margin_ratio=0.0):
```

Replace placement range logic with:

```python
    margin = int(size * placement_margin_ratio)
    max_x = size - new_w - max(8, margin)
    max_y = size - new_h - max(8, margin)
    min_x = max(8, margin)
    min_y = max(8, margin)
    if max_x <= min_x or max_y <= min_y:
        return None
    x = rng.randint(min_x, max_x)
    y = rng.randint(min_y, max_y)
```

Update the call in `build_dataset`:

```python
                box = paste_cutout(
                    canvas,
                    *rng.choice(cutouts),
                    rng,
                    placement_margin_ratio=args.placement_margin_ratio
                    if templates
                    else 0.0,
                )
```

- [ ] **Step 4: Run tests to verify template support passes**

Run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.test_build_bread_yolo_synth -v
```

Expected: PASS for 8 tests.

- [ ] **Step 5: Generate a tiny smoke dataset**

Run this only if `C:\workspace\bakery_vision\data\manifests\bixolon_bakery_raw_v0.1.0.csv` and `C:\workspace\bakery_vision\data\raw\bixolon_bakery\images` exist:

```powershell
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\build_bread_yolo_synth.py `
  --output C:\workspace\bbox\outputs\training\tray_synth_smoke `
  --train 2 `
  --val 1 `
  --size 320 `
  --tray-template-dir C:\workspace\bbox\datasets\bread_tray_templates_v0_1\generated `
  --negative-image-dir C:\workspace\bbox\datasets\bread_tray_negatives_v0_1\generated `
  --negative-train 1 `
  --negative-val 1
```

Expected when source data exists: `dataset.yaml` is written and at least `images/train/train_00000.jpg` exists. If source data is absent, record that smoke generation was skipped due to missing local raw data.

- [ ] **Step 6: Commit**

Run:

```powershell
if ((git rev-parse --is-inside-work-tree) -eq 'true') {
  git add tools/experiments/build_bread_yolo_synth.py test/tools/test_build_bread_yolo_synth.py
  git commit -m "feat: synthesize bread data on real tray templates"
}
```

Expected: Commit is created when the workspace is a git repository.

---

### Task 4: Prepare Held-Out Tray Evaluation Dataset

**Files:**
- Create: `tools/experiments/prepare_tray_eval_dataset.py`
- Create: `docs/training/tray-data-workflow.md`

**Interfaces:**
- Produces CLI: `prepare_tray_eval_dataset.py --output <dataset> --images <path>...`
- Produces dataset shell:
  - `images/<source-name>.jpg`
  - `labels/`
  - `labeling_manifest.csv`
  - `dataset.yaml`
  - `README.md`

- [ ] **Step 1: Create eval preparation script**

Create `tools/experiments/prepare_tray_eval_dataset.py`:

```python
import argparse
import csv
import shutil
from pathlib import Path


SUPPORTED_IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def copy_eval_images(output, image_paths):
    image_dir = output / "images"
    label_dir = output / "labels"
    image_dir.mkdir(parents=True, exist_ok=True)
    label_dir.mkdir(parents=True, exist_ok=True)
    rows = []
    for source in image_paths:
        if source.suffix.lower() not in SUPPORTED_IMAGE_SUFFIXES:
            continue
        target = image_dir / source.name
        shutil.copy2(source, target)
        rows.append(
            {
                "image": target.relative_to(output).as_posix(),
                "label": (label_dir / f"{source.stem}.txt")
                .relative_to(output)
                .as_posix(),
                "status": "needs_manual_label",
            }
        )
    return rows


def write_dataset_yaml(output):
    (output / "dataset.yaml").write_text(
        "\n".join(
            [
                f"path: {output.resolve().as_posix()}",
                "val: images",
                "names:",
                "  0: bread",
                "",
            ]
        ),
        encoding="utf-8",
    )


def write_manifest(output, rows):
    with (output / "labeling_manifest.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["image", "label", "status"])
        writer.writeheader()
        writer.writerows(rows)


def write_readme(output):
    (output / "README.md").write_text(
        "\n".join(
            [
                "# Bread Tray Evaluation Dataset",
                "",
                "This dataset is held out for operating-environment evaluation.",
                "Label each individual bread object as class `0 bread`.",
                "Do not use these images for training until another fixed held-out set exists.",
                "",
            ]
        ),
        encoding="utf-8",
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(r"C:\workspace\bbox\datasets\bread_tray_eval_v0_1"),
    )
    parser.add_argument("--images", type=Path, nargs="+", required=True)
    args = parser.parse_args()

    rows = copy_eval_images(args.output, args.images)
    write_manifest(args.output, rows)
    write_dataset_yaml(args.output)
    write_readme(args.output)
    print(f"images={len(rows)} output={args.output.resolve()}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run eval preparation for the provided images**

Run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\prepare_tray_eval_dataset.py `
  --output C:\workspace\bbox\datasets\bread_tray_eval_v0_1 `
  --images C:\workspace\E0701.jpg C:\workspace\M0711.jpg
```

Expected: output prints `images=2`, and `datasets/bread_tray_eval_v0_1/images/E0701.jpg` plus `images/M0711.jpg` exist.

- [ ] **Step 3: Add workflow documentation**

Create `docs/training/tray-data-workflow.md`:

```markdown
# Tray Data Workflow

## Roles

- `datasets/bread_tray_eval_v0_1`: held-out operating images. Do not train on these first.
- `datasets/bread_tray_negatives_v0_1/generated`: AI-generated empty tray negatives.
- `datasets/bread_tray_negatives_v0_1/real`: real empty tray negatives collected from the operating setup.
- `datasets/bread_tray_templates_v0_1/generated`: AI-generated empty tray templates used as synthetic backgrounds.
- `datasets/bread_tray_templates_v0_1/real`: real empty tray templates used as synthetic backgrounds.
- `outputs/training/bread_yolov8n_1class_tray_v0_2`: generated training run output.

## Prepare Held-Out Evaluation

```powershell
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\prepare_tray_eval_dataset.py `
  --output C:\workspace\bbox\datasets\bread_tray_eval_v0_1 `
  --images C:\workspace\E0701.jpg C:\workspace\M0711.jpg
```

Manually label every individual bread in the evaluation images as class `0 bread`.

## Generate Tray Synthetic Dataset

```powershell
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\build_bread_yolo_synth.py `
  --output C:\workspace\bbox\datasets\bread_tray_synth_v0_2 `
  --train 800 `
  --val 160 `
  --size 640 `
  --tray-template-dir C:\workspace\bbox\datasets\bread_tray_templates_v0_1\generated `
  --negative-image-dir C:\workspace\bbox\datasets\bread_tray_negatives_v0_1\generated `
  --negative-train 80 `
  --negative-val 16 `
  --template-probability 0.75
```

## Train Detector

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m ultralytics train `
  model=yolov8n.pt `
  data=C:\workspace\bbox\datasets\bread_tray_synth_v0_2\dataset.yaml `
  epochs=12 `
  patience=4 `
  batch=8 `
  imgsz=512 `
  device=cpu `
  project=C:\workspace\bbox\outputs\training `
  name=bread_yolov8n_1class_tray_v0_2 `
  exist_ok=True
```

## Promotion Rule

Copy the new `best.pt` into `models/bread_yolov8n_1class_best.pt` only after held-out tray evaluation shows fewer large grouped boxes, fewer empty-tray false positives, and acceptable individual bread recall.
```

- [ ] **Step 4: Commit**

Run:

```powershell
if ((git rev-parse --is-inside-work-tree) -eq 'true') {
  git add tools/experiments/prepare_tray_eval_dataset.py docs/training/tray-data-workflow.md
  git commit -m "docs: define tray data workflow"
}
```

Expected: Commit is created when the workspace is a git repository.

---

### Task 5: Add Held-Out Tray Evaluation Metrics

**Files:**
- Create: `tools/experiments/evaluate_tray_detector.py`
- Create: `test/tools/test_evaluate_tray_detector.py`
- Modify: `docs/training/tray-data-workflow.md`

**Interfaces:**
- Produces: `Box = dict[str, float]`
- Produces: `load_yolo_boxes(path: Path, image_width: int, image_height: int) -> list[dict[str, float]]`
- Produces: `iou(a: dict[str, float], b: dict[str, float]) -> float`
- Produces: `count_group_boxes(predictions: list[dict[str, float]], ground_truth: list[dict[str, float]]) -> int`
- Produces: `evaluate_image(predictions: list[dict[str, float]], ground_truth: list[dict[str, float]], iou_threshold: float = 0.5) -> dict[str, int]`
- Produces CLI: `evaluate_tray_detector.py --dataset <dataset> --predictions <json-dir>`

- [ ] **Step 1: Write failing evaluator tests**

Create `test/tools/test_evaluate_tray_detector.py`:

```python
import importlib.util
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = (
    Path(__file__).resolve().parents[2]
    / "tools"
    / "experiments"
    / "evaluate_tray_detector.py"
)
SPEC = importlib.util.spec_from_file_location("evaluate_tray_detector", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
eval_tray = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(eval_tray)


class EvaluateTrayDetectorTest(unittest.TestCase):
    def test_load_yolo_boxes_converts_normalized_coordinates(self):
        with tempfile.TemporaryDirectory() as temp:
            label = Path(temp) / "image.txt"
            label.write_text("0 0.500000 0.250000 0.200000 0.100000\n", encoding="utf-8")

            boxes = eval_tray.load_yolo_boxes(label, image_width=1000, image_height=800)

            self.assertEqual(
                boxes,
                [{"x": 400.0, "y": 160.0, "width": 200.0, "height": 80.0}],
            )

    def test_iou_returns_overlap_ratio(self):
        a = {"x": 0.0, "y": 0.0, "width": 10.0, "height": 10.0}
        b = {"x": 5.0, "y": 5.0, "width": 10.0, "height": 10.0}

        self.assertAlmostEqual(eval_tray.iou(a, b), 25 / 175)

    def test_count_group_boxes_detects_prediction_covering_two_breads(self):
        prediction = [{"x": 0.0, "y": 0.0, "width": 100.0, "height": 100.0}]
        ground_truth = [
            {"x": 10.0, "y": 10.0, "width": 20.0, "height": 20.0},
            {"x": 60.0, "y": 60.0, "width": 20.0, "height": 20.0},
        ]

        self.assertEqual(eval_tray.count_group_boxes(prediction, ground_truth), 1)

    def test_evaluate_image_counts_matches_false_positives_and_misses(self):
        predictions = [
            {"x": 0.0, "y": 0.0, "width": 20.0, "height": 20.0},
            {"x": 80.0, "y": 80.0, "width": 10.0, "height": 10.0},
        ]
        ground_truth = [
            {"x": 1.0, "y": 1.0, "width": 20.0, "height": 20.0},
            {"x": 40.0, "y": 40.0, "width": 10.0, "height": 10.0},
        ]

        metrics = eval_tray.evaluate_image(predictions, ground_truth, iou_threshold=0.5)

        self.assertEqual(metrics["matched"], 1)
        self.assertEqual(metrics["false_positives"], 1)
        self.assertEqual(metrics["missed"], 1)
        self.assertEqual(metrics["group_boxes"], 0)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run evaluator tests to verify they fail**

Run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.test_evaluate_tray_detector -v
```

Expected: FAIL because `tools/experiments/evaluate_tray_detector.py` does not exist.

- [ ] **Step 3: Implement evaluator**

Create `tools/experiments/evaluate_tray_detector.py`:

```python
import argparse
import json
from pathlib import Path

import cv2
import numpy as np


def decode_image(path):
    data = np.fromfile(str(path), dtype=np.uint8)
    if data.size == 0:
        return None
    return cv2.imdecode(data, cv2.IMREAD_COLOR)


def load_yolo_boxes(path, image_width, image_height):
    if not path.exists():
        return []
    boxes = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) < 5 or parts[0] != "0":
            continue
        cx, cy, width, height = [float(value) for value in parts[1:5]]
        box_width = width * image_width
        box_height = height * image_height
        boxes.append(
            {
                "x": cx * image_width - box_width / 2,
                "y": cy * image_height - box_height / 2,
                "width": box_width,
                "height": box_height,
            }
        )
    return boxes


def area(box):
    return max(0.0, box["width"]) * max(0.0, box["height"])


def intersection(a, b):
    ax1, ay1 = a["x"], a["y"]
    ax2, ay2 = ax1 + a["width"], ay1 + a["height"]
    bx1, by1 = b["x"], b["y"]
    bx2, by2 = bx1 + b["width"], by1 + b["height"]
    width = max(0.0, min(ax2, bx2) - max(ax1, bx1))
    height = max(0.0, min(ay2, by2) - max(ay1, by1))
    return width * height


def iou(a, b):
    overlap = intersection(a, b)
    union = area(a) + area(b) - overlap
    return 0.0 if union <= 0 else overlap / union


def contains_center(container, item):
    center_x = item["x"] + item["width"] / 2
    center_y = item["y"] + item["height"] / 2
    return (
        container["x"] <= center_x <= container["x"] + container["width"]
        and container["y"] <= center_y <= container["y"] + container["height"]
    )


def count_group_boxes(predictions, ground_truth):
    count = 0
    for prediction in predictions:
        contained = sum(1 for truth in ground_truth if contains_center(prediction, truth))
        if contained >= 2:
            count += 1
    return count


def evaluate_image(predictions, ground_truth, iou_threshold=0.5):
    matched_truth = set()
    matched_predictions = set()
    for pred_index, prediction in enumerate(predictions):
        best_truth = None
        best_iou = 0.0
        for truth_index, truth in enumerate(ground_truth):
            if truth_index in matched_truth:
                continue
            score = iou(prediction, truth)
            if score > best_iou:
                best_iou = score
                best_truth = truth_index
        if best_truth is not None and best_iou >= iou_threshold:
            matched_truth.add(best_truth)
            matched_predictions.add(pred_index)

    return {
        "ground_truth": len(ground_truth),
        "predictions": len(predictions),
        "matched": len(matched_truth),
        "false_positives": len(predictions) - len(matched_predictions),
        "missed": len(ground_truth) - len(matched_truth),
        "group_boxes": count_group_boxes(predictions, ground_truth),
        "empty_image_false_positive": int(len(ground_truth) == 0 and len(predictions) > 0),
    }


def load_prediction_json(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    return [
        {
            "x": float(box["x"]),
            "y": float(box["y"]),
            "width": float(box["width"]),
            "height": float(box["height"]),
        }
        for box in data.get("boxes", [])
    ]


def evaluate_dataset(dataset, predictions_dir):
    totals = {
        "images": 0,
        "ground_truth": 0,
        "predictions": 0,
        "matched": 0,
        "false_positives": 0,
        "missed": 0,
        "group_boxes": 0,
        "empty_image_false_positive": 0,
    }
    details = []
    for image_path in sorted((dataset / "images").glob("*")):
        if image_path.suffix.lower() not in {".jpg", ".jpeg", ".png", ".bmp", ".webp"}:
            continue
        image = decode_image(image_path)
        if image is None:
            continue
        height, width = image.shape[:2]
        truth = load_yolo_boxes(dataset / "labels" / f"{image_path.stem}.txt", width, height)
        prediction_path = predictions_dir / f"{image_path.stem}.json"
        predictions = load_prediction_json(prediction_path) if prediction_path.exists() else []
        metrics = evaluate_image(predictions, truth)
        details.append({"image": image_path.name, **metrics})
        totals["images"] += 1
        for key, value in metrics.items():
            totals[key] += value
    return {"totals": totals, "images": details}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--predictions", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    report = evaluate_dataset(args.dataset, args.predictions)
    text = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run evaluator tests to verify they pass**

Run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest test.tools.test_evaluate_tray_detector -v
```

Expected: PASS for 4 tests.

- [ ] **Step 5: Update workflow docs with evaluation command**

Append to `docs/training/tray-data-workflow.md`:

```markdown
## Evaluate Held-Out Tray Predictions

Save detector sidecar JSON outputs as one file per image:

```text
outputs/evaluation/bread_yolov8n_1class_tray_v0_2_predictions/
  E0701.json
  M0711.json
```

Then run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe tools\experiments\evaluate_tray_detector.py `
  --dataset C:\workspace\bbox\datasets\bread_tray_eval_v0_1 `
  --predictions C:\workspace\bbox\outputs\evaluation\bread_yolov8n_1class_tray_v0_2_predictions `
  --output C:\workspace\bbox\outputs\evaluation\bread_yolov8n_1class_tray_v0_2_report.json
```

Promotion requires lower `group_boxes` and `empty_image_false_positive` than the current model while keeping `missed` low.
```

- [ ] **Step 6: Commit**

Run:

```powershell
if ((git rev-parse --is-inside-work-tree) -eq 'true') {
  git add tools/experiments/evaluate_tray_detector.py test/tools/test_evaluate_tray_detector.py docs/training/tray-data-workflow.md
  git commit -m "feat: add tray detector evaluation metrics"
}
```

Expected: Commit is created when the workspace is a git repository.

---

## Final Verification

- [ ] **Step 1: Run Python unit tests**

Run:

```powershell
& C:\workspace\bbox\runtime\python\python.exe -m unittest `
  test.tools.test_build_bread_yolo_synth `
  test.tools.test_evaluate_tray_detector `
  -v
```

Expected: all Python tests pass.

- [ ] **Step 2: Run existing Flutter tests**

Run:

```powershell
flutter test
```

Expected: all existing Flutter tests pass. If Flutter is unavailable, record the exact missing-tool error.

- [ ] **Step 3: Confirm no stale `nest` references returned**

Run:

```powershell
rg -n "C:\\workspace\\bbox\\nest|\bnest\b|nest\\|nest/|nest_policy" README.md docs tools lib test models outputs -S -g '!runtime/**' -g '!build/**'
```

Expected: no matches.

- [ ] **Step 4: Confirm new workflow uses the approved dataset roles**

Run:

```powershell
Get-Content -LiteralPath docs\training\tray-data-workflow.md
```

Expected: the document includes `bread_tray_eval_v0_1`, `bread_tray_negatives_v0_1`, `bread_tray_templates_v0_1`, and `bread_tray_synth_v0_2`.
