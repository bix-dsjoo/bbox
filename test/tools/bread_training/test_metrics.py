import unittest

from tools.bread_training.metrics import (
    DetectorReport,
    detector_gate,
    detector_report,
    match_detections,
)


class DetectorMetricsTest(unittest.TestCase):
    def test_one_prediction_matches_only_one_ground_truth(self):
        ground_truth = [(0, 0, 10, 10), (2, 0, 10, 10)]
        predictions = [(1, 0, 10, 10)]

        result = match_detections(ground_truth, predictions, iou_threshold=0.5)

        self.assertEqual(result.matches, 1)
        self.assertEqual(result.misses, 1)
        self.assertEqual(result.false_positives, 0)

    def test_matching_is_deterministic_when_ious_tie(self):
        ground_truth = [(0, 0, 10, 10)]
        predictions = [(0, 0, 10, 10), (0, 0, 10, 10)]

        result = match_detections(ground_truth, predictions)

        self.assertEqual(result.matched_pairs, ((0, 0),))
        self.assertEqual(result.false_positives, 1)

    def test_matching_finds_all_valid_pairs_when_highest_iou_edges_contend(self):
        ground_truth = [(0, 0, 3, 10), (0, 0, 2, 10)]
        predictions = [(0, 0, 3, 10), (0, 0, 5, 10)]

        result = match_detections(ground_truth, predictions, iou_threshold=0.5)

        self.assertEqual(result.matches, 2)
        self.assertEqual(result.matched_pairs, ((0, 1), (1, 0)))

    def test_detector_report_aggregates_each_fold_as_a_pairing_unit(self):
        small_fold = DetectorReport(
            recall=1.0,
            precision=1.0,
            map50_95=1.0,
            median_iou=1.0,
            median_area_ratio=1.0,
        )
        large_fold = DetectorReport(
            recall=0.0,
            precision=0.0,
            map50_95=0.0,
            median_iou=0.5,
            median_area_ratio=0.5,
        )

        report = detector_report([small_fold, large_fold])

        self.assertEqual(report.recall, 0.5)
        self.assertEqual(report.precision, 0.5)
        self.assertEqual(report.map50_95, 0.5)
        self.assertEqual(report.median_iou, 0.75)
        self.assertEqual(report.median_area_ratio, 0.75)

    def test_detector_gate_rejects_loose_high_recall_candidate(self):
        baseline = DetectorReport(
            recall=0.73,
            precision=0.982,
            map50_95=0.70,
            median_iou=0.99,
            median_area_ratio=1.00,
        )
        candidate = DetectorReport(
            recall=0.91,
            precision=0.98,
            map50_95=0.72,
            median_iou=0.93,
            median_area_ratio=1.08,
        )

        decision = detector_gate(baseline, candidate, median_latency_ms=700)

        self.assertFalse(decision.accepted)
        self.assertIn("median_area_ratio", decision.failed_gates)
        self.assertIn("median_iou", decision.failed_gates)

    def test_detector_gate_accepts_values_on_every_exact_boundary(self):
        baseline = DetectorReport(
            recall=0.80,
            precision=0.98,
            map50_95=0.70,
            median_iou=0.97,
            median_area_ratio=1.00,
        )
        candidate = DetectorReport(
            recall=0.85,
            precision=0.97,
            map50_95=0.70,
            median_iou=0.95,
            median_area_ratio=0.95,
        )

        decision = detector_gate(baseline, candidate, median_latency_ms=1000)

        self.assertTrue(decision.accepted)
        self.assertEqual(decision.failed_gates, ())

    def test_detector_gate_rejects_value_just_below_exact_precision_minimum(self):
        baseline = DetectorReport(0.80, 0.97, 0.70, 0.97, 1.00)
        candidate = DetectorReport(0.85, 0.9699999995, 0.70, 0.95, 1.05)

        decision = detector_gate(baseline, candidate, median_latency_ms=1000)

        self.assertFalse(decision.accepted)
        self.assertIn("precision_absolute", decision.failed_gates)


if __name__ == "__main__":
    unittest.main()
