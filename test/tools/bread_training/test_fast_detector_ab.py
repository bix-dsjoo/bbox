import json
import tempfile
import unittest
from pathlib import Path

from tools.bread_training.fast_detector_ab import (
    CandidateSummary,
    FastAbConfig,
    choose_fast_candidate,
    run_fast_ab,
)
from tools.bread_training.metrics import DetectorReport
from tools.bread_training.train import DetectorCandidateReport


class FastDetectorAbTest(unittest.TestCase):
    def test_choose_rejects_candidate_with_two_misses_in_one_image(self):
        candidate_b = CandidateSummary("b", 3, 0, 2, 0.97, 120.0)
        candidate_a = CandidateSummary("a", 4, 1, 1, 0.95, 130.0)

        selected = choose_fast_candidate((candidate_b, candidate_a))

        self.assertEqual(selected.name, "a")

    def test_choose_uses_misses_false_positives_iou_then_latency(self):
        candidate_a = CandidateSummary("a", 1, 2, 1, 0.96, 130.0)
        candidate_b = CandidateSummary("b", 1, 1, 1, 0.95, 140.0)

        selected = choose_fast_candidate((candidate_a, candidate_b))

        self.assertEqual(selected.name, "b")

    def test_orchestrator_runs_two_screens_but_only_winner_full_oof(self):
        calls = []

        def fake_runner(config):
            calls.append((config.name, config.folds, config.epochs))
            is_b = config.name == "candidate_b2_recall"
            misses = 0 if is_b else 1
            false_positives = 0 if is_b else 1
            artifacts = tuple(
                {
                    "fold": fold,
                    "model_sha256": str(fold) * 64,
                    "images": [
                        {
                            "image_key": f"fold-{fold}.jpg",
                            "misses": misses,
                            "false_positives": false_positives,
                        }
                    ],
                }
                for fold in config.folds
            )
            config.output_root.mkdir(parents=True, exist_ok=True)
            (config.output_root / "candidate_report.json").write_text(
                json.dumps({"candidate": config.name}), encoding="utf-8"
            )
            return DetectorCandidateReport(
                name=config.name,
                fold_artifacts=artifacts,
                report=DetectorReport(
                    recall=1.0,
                    precision=1.0,
                    map50_95=0.95,
                    median_iou=0.97 if is_b else 0.95,
                    median_area_ratio=1.0,
                ),
                median_latency_ms=120.0 if is_b else 130.0,
                best_epochs=tuple(1 for _ in config.folds),
            )

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current = root / "deprecated.pt"
            current.write_bytes(b"seed")
            result = run_fast_ab(
                FastAbConfig(
                    current_weights=current,
                    fold_dataset_root=root / "datasets",
                    output_root=root / "outputs",
                ),
                candidate_runner=fake_runner,
            )
            selection = json.loads(
                (root / "outputs" / "fast_selection.json").read_text(
                    encoding="utf-8"
                )
            )

        self.assertEqual(
            calls,
            [
                ("candidate_a2_tight", (0,), 12),
                ("candidate_b2_recall", (0,), 12),
                ("candidate_b2_recall", (0, 1, 2, 3, 4), 60),
            ],
        )
        self.assertEqual(result.winner, "candidate_b2_recall")
        self.assertEqual(selection["winner"], "candidate_b2_recall")
        self.assertEqual(selection["fullOof"]["maxImageMisses"], 0)


if __name__ == "__main__":
    unittest.main()
