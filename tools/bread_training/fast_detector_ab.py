"""Run a short A/B detector screen followed by winner-only five-fold OOF."""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from typing import Callable, Sequence

from tools.bread_training.train import (
    DetectorCandidateConfig,
    DetectorCandidateReport,
    fast_detector_candidate_matrix,
    run_detector_candidate_oof,
)


@dataclass(frozen=True)
class CandidateSummary:
    name: str
    total_misses: int
    false_positives: int
    max_image_misses: int
    median_iou: float
    median_latency_ms: float


@dataclass(frozen=True)
class FastAbConfig:
    current_weights: Path
    fold_dataset_root: Path
    output_root: Path


@dataclass(frozen=True)
class FastAbResult:
    winner: str
    selection_path: Path
    screen: tuple[CandidateSummary, ...]
    full_oof: CandidateSummary


CandidateRunner = Callable[[DetectorCandidateConfig], DetectorCandidateReport]


def summarize_candidate(report: DetectorCandidateReport) -> CandidateSummary:
    misses = [
        int(image["misses"])
        for artifact in report.fold_artifacts
        for image in artifact["images"]
    ]
    false_positives = sum(
        int(image["false_positives"])
        for artifact in report.fold_artifacts
        for image in artifact["images"]
    )
    return CandidateSummary(
        name=report.name,
        total_misses=sum(misses),
        false_positives=false_positives,
        max_image_misses=max(misses, default=0),
        median_iou=float(report.report.median_iou),
        median_latency_ms=float(report.median_latency_ms),
    )


def choose_fast_candidate(
    summaries: Sequence[CandidateSummary],
) -> CandidateSummary:
    valid = [item for item in summaries if item.max_image_misses <= 1]
    if not valid:
        raise RuntimeError("A2 and B2 both have an image with at least two misses")
    return min(
        valid,
        key=lambda item: (
            item.total_misses,
            item.false_positives,
            -item.median_iou,
            item.median_latency_ms,
            item.name,
        ),
    )


def _sha256_if_file(path: Path) -> str | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _profile(config: DetectorCandidateConfig) -> dict[str, object]:
    return {
        "mosaic": config.mosaic,
        "closeMosaic": config.close_mosaic,
        "translate": config.translate,
        "scale": config.scale,
        "syntheticRatio": config.synthetic_ratio,
    }


def _write_json_atomic(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8", newline="\n") as stream:
        json.dump(payload, stream, indent=2, ensure_ascii=False)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def run_fast_ab(
    config: FastAbConfig,
    *,
    candidate_runner: CandidateRunner = run_detector_candidate_oof,
) -> FastAbResult:
    screen_root = config.output_root / "screen"
    screen_configs = fast_detector_candidate_matrix(
        config.current_weights,
        config.fold_dataset_root,
        screen_root,
    )
    screen_reports = tuple(candidate_runner(item) for item in screen_configs)
    screen_summaries = tuple(summarize_candidate(item) for item in screen_reports)
    winner_summary = choose_fast_candidate(screen_summaries)
    winner_config = next(
        item for item in screen_configs if item.name == winner_summary.name
    )
    full_config = replace(
        winner_config,
        output_root=config.output_root / "full_5fold" / winner_config.name,
        folds=(0, 1, 2, 3, 4),
        epochs=60,
        patience=10,
    )
    full_report = candidate_runner(full_config)
    full_summary = summarize_candidate(full_report)
    if full_summary.max_image_misses > 1:
        raise RuntimeError(
            f"{full_summary.name} five-fold OOF has an image with at least two misses"
        )

    selection_path = config.output_root / "fast_selection.json"
    _write_json_atomic(
        selection_path,
        {
            "schemaVersion": 1,
            "selectionPolicy": "misses_false_positives_iou_latency_v1",
            "winner": full_config.name,
            "initialWeights": str(full_config.initial_weights),
            "initialWeightsSha256": _sha256_if_file(full_config.initial_weights),
            "trainingProfile": _profile(full_config),
            "screen": [asdict(item) for item in screen_summaries],
            "fullOof": {
                "summary": asdict(full_summary),
                "maxImageMisses": full_summary.max_image_misses,
                "candidateReport": str(
                    (full_config.output_root / "candidate_report.json").resolve()
                ),
                "artifacts": [
                    {
                        "fold": int(artifact["fold"]),
                        "path": str(
                            (
                                full_config.output_root
                                / f"fold_{int(artifact['fold'])}_predictions.json"
                            ).resolve()
                        ),
                        "modelSha256": str(artifact["model_sha256"]),
                    }
                    for artifact in full_report.fold_artifacts
                ],
            },
        },
    )
    return FastAbResult(
        winner=full_config.name,
        selection_path=selection_path,
        screen=screen_summaries,
        full_oof=full_summary,
    )
