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
        args = type("Args", (), {"size": 32, "template_probability": 1.0})()
        rng = build_synth.random.Random(123)

        canvas = build_synth.make_canvas(args, rng, [template])

        self.assertEqual(canvas.shape, (32, 32, 3))
        self.assertGreater(int(canvas.mean()), 70)

    def test_box_overlap_ratio_measures_candidate_coverage(self):
        candidate = (0.0, 0.0, 100.0, 100.0)
        existing = (50.0, 0.0, 100.0, 100.0)

        ratio = build_synth.box_overlap_ratio(candidate, existing)

        self.assertAlmostEqual(ratio, 0.5)

    def test_box_overlaps_existing_respects_threshold(self):
        candidate = (0.0, 0.0, 100.0, 100.0)
        existing = [(80.0, 0.0, 100.0, 100.0)]

        self.assertFalse(
            build_synth.box_overlaps_existing(
                candidate,
                existing,
                max_overlap_ratio=0.25,
            )
        )
        self.assertTrue(
            build_synth.box_overlaps_existing(
                candidate,
                existing,
                max_overlap_ratio=0.10,
            )
        )

    def test_keep_largest_mask_component_removes_detached_fragments(self):
        mask = np.zeros((80, 120), dtype=np.uint8)
        mask[20:60, 15:55] = 255
        mask[5:18, 90:112] = 255

        cleaned = build_synth.keep_largest_mask_component(mask)

        self.assertEqual(int(cleaned[30, 30]), 255)
        self.assertEqual(int(cleaned[10, 100]), 0)

    def test_clean_bread_mask_preserves_main_blob_and_removes_noise(self):
        mask = np.zeros((100, 100), dtype=np.uint8)
        cv2.circle(mask, (45, 50), 22, 255, -1)
        cv2.rectangle(mask, (85, 8), (94, 17), 255, -1)

        cleaned = build_synth.clean_bread_mask(mask)

        self.assertGreater(cv2.countNonZero(cleaned[25:75, 20:70]), 1000)
        self.assertEqual(cv2.countNonZero(cleaned[5:25, 80:98]), 0)

    def test_make_cutout_contact_sheet_writes_preview_image(self):
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "cutouts.jpg"
            crop = np.zeros((16, 20, 3), dtype=np.uint8)
            crop[:, :] = (20, 80, 180)
            alpha = np.zeros((16, 20), dtype=np.float32)
            alpha[4:12, 5:15] = 1.0

            written = build_synth.make_cutout_contact_sheet(
                [(crop, alpha, (5, 4, 10, 8))],
                output,
                tile_size=48,
                columns=2,
            )

            self.assertEqual(written, 1)
            self.assertTrue(output.exists())
            preview = cv2.imread(str(output))
            self.assertEqual(preview.shape[:2], (48, 96))

    def test_cutout_warm_pixel_ratio_rejects_gray_background_fragment(self):
        crop = np.zeros((20, 20, 3), dtype=np.uint8)
        crop[:, :] = (60, 62, 64)
        alpha = np.ones((20, 20), dtype=np.float32)

        ratio = build_synth.cutout_warm_pixel_ratio(crop, alpha)

        self.assertLess(ratio, 0.1)
        self.assertFalse(build_synth.cutout_is_usable(crop, alpha))

    def test_cutout_warm_pixel_ratio_accepts_warm_bread_fragment(self):
        crop = np.zeros((20, 20, 3), dtype=np.uint8)
        crop[:, :] = (45, 130, 220)
        alpha = np.ones((20, 20), dtype=np.float32)

        ratio = build_synth.cutout_warm_pixel_ratio(crop, alpha)

        self.assertGreater(ratio, 0.9)
        self.assertTrue(build_synth.cutout_is_usable(crop, alpha))

    def test_build_dataset_writes_cutout_contact_sheet_when_requested(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            image_root = root / "raw"
            image_root.mkdir()
            manifest = root / "manifest.csv"
            rows = ["relative_path"]
            for index in range(20):
                image = np.zeros((80, 80, 3), dtype=np.uint8)
                cv2.ellipse(image, (40, 42), (24, 16), 0, 0, 360, (45, 130, 220), -1)
                image_name = f"bread_{index:03d}.jpg"
                cv2.imencode(".jpg", image)[1].tofile(str(image_root / image_name))
                rows.append(image_name)
            manifest.write_text("\n".join(rows), encoding="utf-8")
            output = root / "dataset"
            contact_sheet = root / "cutouts.jpg"
            args = type(
                "Args",
                (),
                {
                    "manifest": manifest,
                    "image_root": image_root,
                    "output": output,
                    "train": 1,
                    "val": 1,
                    "size": 96,
                    "min_objects": 1,
                    "max_objects": 1,
                    "negative_image_dir": None,
                    "negative_train": 0,
                    "negative_val": 0,
                    "tray_template_dir": None,
                    "template_probability": 0.0,
                    "placement_margin_ratio": 0.0,
                    "placement_attempts": 4,
                    "max_placement_overlap": 0.2,
                    "cutout_contact_sheet": contact_sheet,
                    "cutout_contact_sheet_limit": 12,
                    "seed": 123,
                },
            )()

            build_synth.build_dataset(args)

            self.assertTrue(contact_sheet.exists())
            self.assertTrue((output / "dataset.yaml").exists())


if __name__ == "__main__":
    unittest.main()
