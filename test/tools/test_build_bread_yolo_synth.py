import importlib.util
import unittest
from pathlib import Path

from tools.bread_training import synthetic


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


class BuildBreadYoloSynthCompatibilityTest(unittest.TestCase):
    def test_legacy_entrypoint_uses_leakage_safe_builder(self):
        self.assertIs(build_synth.build_synthetic_fold, synthetic.build_synthetic_fold)

    def test_legacy_entrypoint_uses_exact_mask_bbox(self):
        self.assertIs(build_synth.mask_bbox, synthetic.mask_bbox)

    def test_legacy_entrypoint_exposes_same_cli(self):
        self.assertIs(build_synth.main, synthetic.main)


if __name__ == "__main__":
    unittest.main()
