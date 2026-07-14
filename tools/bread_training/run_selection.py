"""Select, train, publish, and audit the bread inference pipeline."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import re
import shutil
import statistics
import sys
import tempfile
from dataclasses import asdict, dataclass
from decimal import Decimal
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from tools.bread_training.catalog import Catalog
from tools.bread_training.detector_data import build_detector_all_data
from tools.bread_training.metrics import (
    DetectorReport,
    GateDecision,
    LabelPolicy,
    detector_gate,
)
from tools.bread_training.split import load_catalog
from tools.bread_training.train import (
    _class_directory,
    _write_classifier_crop,
    build_classifier_fold_manifest,
)
from tools.bread_training.verifier import (
    VerifierDecision,
    VerifierMetrics,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CLASSIFIER_PRECISION_FLOOR = Decimal("0.94")
PIPELINE_VERSION = "bread-pipeline-v1"
SYNTHETIC_DISABLED_REASON = "no_approved_backgrounds"
CANONICAL_LABELS = (
    "Walnut Donut",
    "Croffle",
    "Waffle",
    "Scon",
    "Half-moon Croissant",
    "Croissant",
    "Flower Bread",
    "Almond Scon",
    "Dinner Roll",
    "Sugar Donut",
    "Bagel",
    "Egg Tart",
    "Muffin",
    "Burger",
    "Sandwich",
    "Grain Campagne",
    "Almond Campagne",
    "Mini Bread",
    "Pastry Bread",
    "Plain Bread",
)


class SelectionError(RuntimeError):
    """Raised when a selection or handoff invariant is not satisfied."""


@dataclass(frozen=True)
class SelectionConfig:
    raw_root: Path
    catalog_path: Path
    split_path: Path
    baseline_detector_report: Path
    candidate_root: Path
    classifier_root: Path
    output_root: Path
    manifest_path: Path


@dataclass(frozen=True)
class ClassifierPublication:
    path: Path
    newly_published: bool


@dataclass(frozen=True)
class ModelSelection:
    name: str
    path: Path
    sha256: str
    report: DetectorReport | Mapping[str, Any]
    confidence: float
    iou: float
    median_latency_ms: float


@dataclass(frozen=True)
class SelectionReport:
    catalog: Catalog
    baseline_detector: ModelSelection
    detector: ModelSelection
    detector_gate: GateDecision
    classifier: ModelSelection
    label_policy: LabelPolicy
    classifier_policy_report: Mapping[str, Any]
    verifier: VerifierDecision
    synthetic_disabled_reason: str


def sha256_file(path: Path) -> str:
    if not path.is_file():
        raise SelectionError(f"selected file does not exist: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _guard_output_path(path: Path) -> Path:
    resolved = path.resolve()
    allowed = (REPOSITORY_ROOT / "outputs").resolve()
    try:
        resolved.relative_to(allowed)
    except ValueError as error:
        raise SelectionError(f"output must be below repository outputs: {allowed}") from error
    return resolved


def _guard_manifest_path(path: Path) -> Path:
    resolved = path.resolve()
    expected = (REPOSITORY_ROOT / "models" / "bread_pipeline_manifest.json").resolve()
    if resolved != expected:
        raise SelectionError(f"manifest must be exactly {expected}")
    return resolved


def _validate_catalog_sources(
    catalog_payload: Mapping[str, Any], raw_root: Path
) -> None:
    resolved_raw = raw_root.resolve()
    images = catalog_payload.get("images")
    if not isinstance(images, list):
        raise SelectionError("catalog images must be a list")
    for image in images:
        if not isinstance(image, dict):
            raise SelectionError("catalog image must be an object")
        source = Path(str(image.get("absolute_path", ""))).resolve()
        try:
            source.relative_to(resolved_raw)
        except ValueError as error:
            raise SelectionError(f"catalog source is outside raw root: {source}") from error
        if sha256_file(source) != image.get("sha256"):
            raise SelectionError(f"catalog source sha256 mismatch: {source}")


def _validate_probability(name: str, value: Any) -> float:
    if type(value) not in (int, float):
        raise SelectionError(f"{name} must be a JSON number")
    number = float(value)
    if not math.isfinite(number) or not 0.0 <= number <= 1.0:
        raise SelectionError(f"{name} must be between 0 and 1")
    return number


def _validate_selected_hash(kind: str, selection: ModelSelection) -> str:
    actual = sha256_file(selection.path)
    if actual != selection.sha256:
        raise SelectionError(f"{kind} sha256 mismatch")
    return actual


def choose_detector(
    baseline: ModelSelection, candidates: Sequence[ModelSelection]
) -> tuple[ModelSelection, GateDecision]:
    if not isinstance(baseline.report, DetectorReport):
        raise SelectionError("baseline detector report is invalid")
    evaluated = tuple(
        (
            candidate,
            detector_gate(
                baseline.report,
                candidate.report,
                candidate.median_latency_ms,
            ),
        )
        for candidate in candidates
        if isinstance(candidate.report, DetectorReport)
    )
    passing = tuple(item for item in evaluated if item[1].accepted)
    if passing:
        selected, decision = max(
            passing,
            key=lambda item: (
                item[0].report.recall,
                item[0].report.map50_95,
                item[0].report.precision,
                -item[0].median_latency_ms,
                item[0].name,
            ),
        )
        return selected, decision
    if evaluated:
        rejected = max(
            evaluated,
            key=lambda item: (
                item[0].report.recall,
                item[0].report.map50_95,
                item[0].report.precision,
                -item[0].median_latency_ms,
                item[0].name,
            ),
        )[1]
        return baseline, rejected
    return baseline, GateDecision(True, (), {"baseline_retained": True})


def median_best_epoch(values: Sequence[Any]) -> int:
    epochs = tuple(
        int(item.best_epoch) if hasattr(item, "best_epoch") else int(item)
        for item in values
    )
    if len(epochs) != 5:
        raise SelectionError("median best epoch requires exactly five folds")
    if any(item <= 0 for item in epochs):
        raise SelectionError("best epochs must be positive")
    return int(statistics.median(epochs))


def build_final_classifier_fingerprint(
    *,
    catalog_sha256: str,
    split_sha256: str,
    dataset_manifest_sha256: str,
    initial_weights_path: Path,
    epochs: int,
) -> dict[str, Any]:
    return {
        "trainerSchemaVersion": 1,
        "catalogSha256": catalog_sha256,
        "splitSha256": split_sha256,
        "datasetManifestSha256": dataset_manifest_sha256,
        "initialWeights": str(initial_weights_path.resolve()),
        "initialWeightsSha256": sha256_file(initial_weights_path),
        "imgsz": 224,
        "device": 0,
        "seed": 20260714,
        "deterministic": True,
        "workers": 0,
        "batch": 64,
        "epochs": int(epochs),
        "validation": False,
        "validationScaffold": "one_training_sample_per_class_for_loader_only",
        "sampleCounts": {"singleImages": 3230, "mixedGroundTruthCrops": 510},
    }


def reusable_final_classifier(
    marker_path: Path, expected_fingerprint: Mapping[str, Any]
) -> Path | None:
    try:
        marker = json.loads(marker_path.read_text(encoding="utf-8"))
        if not isinstance(marker, dict) or marker.get("schemaVersion") != 1:
            return None
        if marker.get("trainingFingerprint") != dict(expected_fingerprint):
            return None
        weights = Path(str(marker["finalWeights"])).resolve()
        weights.relative_to(marker_path.resolve().parent)
        if sha256_file(weights) != marker.get("finalWeightsSha256"):
            return None
        return weights
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError, SelectionError):
        return None


def _detector_manifest(selection: ModelSelection) -> dict[str, Any]:
    _validate_selected_hash("detector", selection)
    return {
        "file": selection.path.name,
        "sha256": selection.sha256,
        "imgsz": 640,
        "confidence": _validate_probability("detector confidence", selection.confidence),
        "iou": _validate_probability("detector iou", selection.iou),
    }


def _classifier_manifest(
    selection: ModelSelection,
    policy: LabelPolicy,
    report: Mapping[str, Any],
) -> dict[str, Any]:
    _validate_selected_hash("classifier", selection)
    precision = _validate_probability("classifier precision", report.get("precision"))
    coverage = _validate_probability("classifier coverage", report.get("coverage"))
    if Decimal(str(precision)) < CLASSIFIER_PRECISION_FLOOR:
        raise SelectionError(
            "classifier deployment precision is below the approved 0.94 floor"
        )
    conservative = [int(item) for item in policy.conservative_classes]
    if conservative != sorted(set(conservative)) or any(
        item not in range(1, 21) for item in conservative
    ):
        raise SelectionError("conservativeClasses must be unique ordered IDs 1 through 20")
    return {
        "file": selection.path.name,
        "sha256": selection.sha256,
        "imgsz": 224,
        "acceptConfidence": _validate_probability(
            "acceptConfidence", policy.confidence
        ),
        "acceptMargin": _validate_probability("acceptMargin", policy.margin),
        "conservativeClasses": conservative,
        "oofPrecision": precision,
        "oofCoverage": coverage,
    }


def build_manifest(selection: SelectionReport) -> dict[str, Any]:
    expected_labels = tuple(enumerate(CANONICAL_LABELS, start=1))
    if (
        selection.catalog.labels != expected_labels
        or any(
            type(category_id) is not int or not isinstance(name, str)
            for category_id, name in selection.catalog.labels
        )
    ):
        raise SelectionError("labels must match the canonical ordered IDs and names")
    if selection.label_policy.version != "bread-label-policy-v2":
        raise SelectionError("policyVersion must be bread-label-policy-v2")
    if selection.verifier.kind != "none":
        raise SelectionError("this approved pipeline requires verifier kind none")
    return {
        "schemaVersion": 1,
        "pipelineVersion": PIPELINE_VERSION,
        "policyVersion": selection.label_policy.version,
        "detector": _detector_manifest(selection.detector),
        "classifier": _classifier_manifest(
            selection.classifier,
            selection.label_policy,
            selection.classifier_policy_report,
        ),
        "verifier": {
            "kind": "none",
            "file": None,
            "sha256": None,
            "scoreThreshold": None,
            "marginThreshold": None,
        },
        "quality": {
            "minBoxSize": 45,
            "maxAreaRatio": 0.38,
            "edgeMarginPx": 2,
            "duplicateIou": 0.95,
        },
        "labels": [
            {"id": category_id, "name": name}
            for category_id, name in selection.catalog.labels
        ],
    }


def _local_model_path(manifest_path: Path, value: Any, kind: str) -> Path:
    filename = Path(str(value))
    if filename.name != str(value) or filename.is_absolute():
        raise SelectionError(f"{kind} file must be a local sibling filename")
    return manifest_path.resolve().parent / filename


def audit_manifest_contract(manifest_path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SelectionError(f"could not read pipeline manifest: {manifest_path}") from error
    expected_top_keys = {
        "schemaVersion",
        "pipelineVersion",
        "policyVersion",
        "detector",
        "classifier",
        "verifier",
        "quality",
        "labels",
    }
    if set(payload) != expected_top_keys:
        raise SelectionError("manifest top-level fields do not match schema v1")
    if type(payload.get("schemaVersion")) is not int or payload["schemaVersion"] != 1:
        raise SelectionError("manifest schemaVersion must be 1")
    if payload.get("pipelineVersion") != PIPELINE_VERSION:
        raise SelectionError(f"manifest pipelineVersion must be {PIPELINE_VERSION}")
    if payload.get("policyVersion") != "bread-label-policy-v2":
        raise SelectionError("manifest policyVersion must be bread-label-policy-v2")
    labels = payload.get("labels")
    expected_labels = [
        {"id": category_id, "name": name}
        for category_id, name in enumerate(CANONICAL_LABELS, start=1)
    ]
    if (
        not isinstance(labels, list)
        or any(
            not isinstance(item, dict)
            or set(item) != {"id", "name"}
            or type(item.get("id")) is not int
            or not isinstance(item.get("name"), str)
            for item in labels
        )
        or labels != expected_labels
    ):
        raise SelectionError("labels must contain ordered IDs 1 through 20")
    expected_model_keys = {
        "detector": {"file", "sha256", "imgsz", "confidence", "iou"},
        "classifier": {
            "file",
            "sha256",
            "imgsz",
            "acceptConfidence",
            "acceptMargin",
            "conservativeClasses",
            "oofPrecision",
            "oofCoverage",
        },
    }
    for kind in ("detector", "classifier"):
        model = payload.get(kind)
        if not isinstance(model, dict):
            raise SelectionError(f"manifest {kind} must be an object")
        if set(model) != expected_model_keys[kind]:
            raise SelectionError(f"manifest {kind} fields do not match schema v1")
        expected_imgsz = 640 if kind == "detector" else 224
        if type(model.get("imgsz")) is not int or model["imgsz"] != expected_imgsz:
            raise SelectionError(f"manifest {kind} imgsz must be {expected_imgsz}")
        if not isinstance(model.get("file"), str) or not isinstance(
            model.get("sha256"), str
        ):
            raise SelectionError(f"manifest {kind} file and sha256 must be strings")
        model_path = _local_model_path(manifest_path, model.get("file"), kind)
        if sha256_file(model_path) != model.get("sha256"):
            raise SelectionError(f"{kind} sha256 mismatch")
    detector = payload["detector"]
    classifier = payload["classifier"]
    expected_classifier_file = (
        f"bread_classifier_yolov8n_cls_v1_{classifier['sha256']}.pt"
    )
    if classifier["file"] != expected_classifier_file:
        raise SelectionError(
            "classifier file must use the exact content-addressed sha256 name"
        )
    for name, value in (
        ("detector confidence", detector.get("confidence")),
        ("detector iou", detector.get("iou")),
        ("acceptConfidence", classifier.get("acceptConfidence")),
        ("acceptMargin", classifier.get("acceptMargin")),
        ("oofPrecision", classifier.get("oofPrecision")),
        ("oofCoverage", classifier.get("oofCoverage")),
    ):
        _validate_probability(name, value)
    if Decimal(str(classifier["oofPrecision"])) < CLASSIFIER_PRECISION_FLOOR:
        raise SelectionError("classifier precision is below the approved 0.94 floor")
    conservative = classifier.get("conservativeClasses")
    if (
        not isinstance(conservative, list)
        or any(type(item) is not int for item in conservative)
        or conservative != sorted(set(conservative))
        or any(item not in range(1, 21) for item in conservative)
    ):
        raise SelectionError("conservativeClasses must be unique ordered IDs 1 through 20")
    verifier = payload.get("verifier")
    expected_verifier = {
        "kind": "none",
        "file": None,
        "sha256": None,
        "scoreThreshold": None,
        "marginThreshold": None,
    }
    if verifier != expected_verifier:
        raise SelectionError("verifier kind none cannot reference files or thresholds")
    quality = payload.get("quality")
    if not isinstance(quality, dict) or set(quality) != {
        "minBoxSize",
        "maxAreaRatio",
        "edgeMarginPx",
        "duplicateIou",
    }:
        raise SelectionError("manifest quality fields do not match schema v1")
    if type(quality.get("minBoxSize")) is not int or quality["minBoxSize"] != 45:
        raise SelectionError("quality minBoxSize must be integer 45")
    if type(quality.get("edgeMarginPx")) is not int or quality["edgeMarginPx"] != 2:
        raise SelectionError("quality edgeMarginPx must be integer 2")
    if type(quality.get("maxAreaRatio")) is not float or quality["maxAreaRatio"] != 0.38:
        raise SelectionError("quality maxAreaRatio must be JSON float 0.38")
    if type(quality.get("duplicateIou")) is not float or quality["duplicateIou"] != 0.95:
        raise SelectionError("quality duplicateIou must be JSON float 0.95")
    if quality != {
        "minBoxSize": 45,
        "maxAreaRatio": 0.38,
        "edgeMarginPx": 2,
        "duplicateIou": 0.95,
    }:
        raise SelectionError("manifest quality settings do not match schema v1")
    return {
        "ok": True,
        "pipelineVersion": PIPELINE_VERSION,
        "verifierKind": "none",
    }


def _publish_manifest(
    manifest_path: Path,
    payload: Mapping[str, Any],
    audit_fn: Callable[[Path], dict[str, Any]] = audit_manifest_contract,
) -> dict[str, Any]:
    target = _guard_manifest_path(manifest_path)
    serialized = (json.dumps(payload, indent=2, ensure_ascii=False) + "\n").encode(
        "utf-8"
    )
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            prefix=".bread_pipeline_manifest.",
            suffix=".json",
            dir=target.parent,
            delete=False,
        ) as stream:
            temporary = Path(stream.name)
            stream.write(serialized)
            stream.flush()
            os.fsync(stream.fileno())
        audit = audit_fn(temporary)
        if audit.get("ok") is not True:
            raise SelectionError("prospective manifest audit did not return ok=true")
        os.replace(temporary, target)
        temporary = None
        return audit
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def _remove_new_classifier_orphan(
    publication: ClassifierPublication, manifest_path: Path
) -> None:
    if not publication.newly_published:
        return
    target = _guard_manifest_path(manifest_path)
    models_root = target.parent.resolve()
    classifier_path = publication.path.resolve()
    if classifier_path.parent != models_root:
        raise SelectionError("classifier cleanup path must be directly inside models")
    digest = sha256_file(classifier_path)
    expected_name = f"bread_classifier_yolov8n_cls_v1_{digest}.pt"
    if classifier_path.name != expected_name:
        raise SelectionError("classifier cleanup path is not exact content-addressed name")
    if target.exists():
        audit_manifest_contract(target)
        previous = _read_json(target, "previous pipeline manifest")
        previous_file = previous.get("classifier", {}).get("file")
        if previous_file == classifier_path.name:
            raise SelectionError(
                "classifier cleanup refuses to remove previous handoff weight"
            )
    try:
        classifier_path.unlink()
    except OSError as error:
        raise SelectionError(
            f"could not remove newly published classifier: {classifier_path}"
        ) from error


def _publish_manifest_with_classifier_cleanup(
    manifest_path: Path,
    payload: Mapping[str, Any],
    publication: ClassifierPublication,
    audit_fn: Callable[[Path], dict[str, Any]] = audit_manifest_contract,
) -> dict[str, Any]:
    try:
        return _publish_manifest(manifest_path, payload, audit_fn=audit_fn)
    except Exception:
        if publication.newly_published:
            try:
                _remove_new_classifier_orphan(publication, manifest_path)
            except Exception as cleanup_error:
                raise SelectionError(
                    "manifest publication failed and classifier cleanup failed"
                ) from cleanup_error
        raise


def _read_json(path: Path, description: str) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SelectionError(f"could not read {description}: {path}") from error
    if not isinstance(payload, dict):
        raise SelectionError(f"{description} must contain a JSON object")
    return payload


def _validate_classifier_provenance(
    payload: Mapping[str, Any],
    classifier_root: Path,
    catalog_payload: Mapping[str, Any],
    split_payload: Mapping[str, Any],
) -> None:
    folds = payload.get("folds")
    valid = (
        type(payload.get("schema_version")) is int
        and payload["schema_version"] == 2
        and payload.get("evaluation_kind")
        == "new_20_class_leakage_safe_5fold_oof"
        and type(payload.get("leakage_safe_oof")) is bool
        and payload["leakage_safe_oof"] is True
        and type(payload.get("sample_count")) is int
        and payload["sample_count"] == 510
        and type(payload.get("calibration_sample_count")) is int
        and payload["calibration_sample_count"] == 3740
        and payload.get("policy_selection_source")
        == "median_of_five_validation_fold_policies"
        and isinstance(folds, list)
        and len(folds) == 5
    )
    if not valid:
        raise SelectionError("classifier provenance is not exact leakage-safe v2 OOF")
    root = classifier_root.resolve()
    expected_fold_keys = {
        "fold",
        "validation_fold",
        "manifest",
        "weights",
        "weights_sha256",
        "fold_policy",
    }
    expected_policy_keys = {
        "version",
        "confidence",
        "margin",
        "conservative_classes",
    }
    expected_manifest_keys = {
        "schema_version",
        "fold",
        "validation_fold",
        "held_out_mixed_keys",
        "validation_mixed_keys",
        "training_mixed_keys",
        "validation_single_keys",
        "training_single_keys",
        "held_out_absent_from_train_val",
        "class_directories",
        "counts",
        "sources",
    }
    for index, item in enumerate(folds):
        if not isinstance(item, dict) or set(item) != expected_fold_keys:
            raise SelectionError("classifier provenance fold fields are not exact")
        if type(item["fold"]) is not int or item["fold"] != index:
            raise SelectionError("classifier provenance fold order is invalid")
        if (
            type(item["validation_fold"]) is not int
            or item["validation_fold"] != (index + 1) % 5
        ):
            raise SelectionError("classifier provenance validation fold is invalid")
        if type(item["manifest"]) is not str or type(item["weights"]) is not str:
            raise SelectionError("classifier provenance artifact paths must be strings")
        manifest_path = Path(item["manifest"]).resolve()
        weights_path = Path(item["weights"]).resolve()
        expected_fold_root = root / f"fold_{index}"
        if (
            manifest_path != expected_fold_root / "fold_manifest.json"
            or weights_path != expected_fold_root / "train" / "weights" / "best.pt"
        ):
            raise SelectionError(
                "classifier provenance artifacts must use canonical fold paths"
            )
        if not manifest_path.is_file() or not weights_path.is_file():
            raise SelectionError("classifier provenance artifacts are missing")
        manifest_payload = _read_json(
            manifest_path, f"classifier fold {index} manifest"
        )
        if set(manifest_payload) != expected_manifest_keys:
            raise SelectionError("classifier provenance manifest fields are not exact")
        try:
            expected_identity = asdict(
                build_classifier_fold_manifest(
                    catalog_payload, split_payload, index
                )
            )
        except (KeyError, TypeError, ValueError) as error:
            raise SelectionError(
                "classifier provenance catalog/split contract is invalid"
            ) from error
        actual_identity = {
            key: manifest_payload[key] for key in expected_identity
        }
        normalized_identity = {
            key: list(value) if isinstance(value, tuple) else value
            for key, value in expected_identity.items()
        }
        if (
            type(manifest_payload["schema_version"]) is not int
            or manifest_payload["schema_version"] != 1
            or actual_identity != normalized_identity
            or type(manifest_payload["held_out_absent_from_train_val"]) is not bool
            or manifest_payload["held_out_absent_from_train_val"] is not True
            or not isinstance(manifest_payload["class_directories"], dict)
            or not isinstance(manifest_payload["counts"], dict)
            or not isinstance(manifest_payload["sources"], list)
        ):
            raise SelectionError("classifier provenance manifest identity is invalid")
        if (
            type(item["weights_sha256"]) is not str
            or not re.fullmatch(r"[0-9a-f]{64}", item["weights_sha256"])
            or sha256_file(weights_path) != item["weights_sha256"]
        ):
            raise SelectionError("classifier provenance weights hash is invalid")
        policy = item["fold_policy"]
        if not isinstance(policy, dict) or set(policy) != expected_policy_keys:
            raise SelectionError("classifier provenance fold policy fields are not exact")
        if policy["version"] != "bread-label-policy-v2":
            raise SelectionError("classifier provenance fold policy version is invalid")
        _validate_probability("classifier provenance confidence", policy["confidence"])
        _validate_probability("classifier provenance margin", policy["margin"])
        classes = policy["conservative_classes"]
        if (
            not isinstance(classes, list)
            or any(type(value) is not int or not 1 <= value <= 20 for value in classes)
            or classes != sorted(set(classes))
        ):
            raise SelectionError(
                "classifier provenance conservative classes are invalid"
            )


def _detector_report(payload: Mapping[str, Any]) -> DetectorReport:
    try:
        metrics = payload["metrics"]
        return DetectorReport(
            recall=float(metrics["recall"]),
            precision=float(metrics["precision"]),
            map50_95=float(metrics["map50_95"]),
            median_iou=float(metrics["median_iou"]),
            median_area_ratio=float(metrics["median_area_ratio"]),
        )
    except (KeyError, TypeError, ValueError) as error:
        raise SelectionError("detector report metrics are malformed") from error


def _load_baseline(path: Path) -> ModelSelection:
    payload = _read_json(path, "baseline detector report")
    weights = Path(str(payload.get("model", ""))).resolve()
    return ModelSelection(
        name="current_detector",
        path=weights,
        sha256=sha256_file(weights),
        report=_detector_report(payload),
        confidence=0.25,
        iou=0.7,
        median_latency_ms=float(payload["median_latency_ms"]),
    )


def _load_candidates(root: Path) -> tuple[ModelSelection, ...]:
    candidates: list[ModelSelection] = []
    for report_path in sorted(root.glob("*/candidate_report.json")):
        payload = _read_json(report_path, "detector candidate report")
        name = str(payload.get("candidate", report_path.parent.name))
        if name != report_path.parent.name or re.fullmatch(r"[a-z0-9_]+", name) is None:
            raise SelectionError("detector candidate name must match its safe directory name")
        weights = report_path.parent / "fold_0" / "weights" / "best.pt"
        thresholds = tuple(
            float(item["confidence_threshold"])
            for item in payload.get("folds", ())
        )
        candidates.append(
            ModelSelection(
                name=name,
                path=weights.resolve(),
                sha256=str(
                    payload.get("folds", [{}])[0].get("model_sha256", "")
                ),
                report=_detector_report(payload),
                confidence=statistics.median(thresholds) if thresholds else 0.25,
                iou=0.7,
                median_latency_ms=float(payload["median_latency_ms"]),
            )
        )
    if not candidates:
        raise SelectionError(f"no detector candidate reports found below {root}")
    return tuple(candidates)


def _classifier_best_epochs(classifier_root: Path) -> tuple[int, ...]:
    best_epochs: list[int] = []
    for fold in range(5):
        path = classifier_root / f"fold_{fold}" / "train" / "results.csv"
        try:
            with path.open("r", encoding="utf-8") as stream:
                rows = tuple(csv.DictReader(stream))
        except OSError as error:
            raise SelectionError(f"could not read classifier results: {path}") from error
        if not rows:
            raise SelectionError(f"classifier results are empty: {path}")
        try:
            best = max(
                rows,
                key=lambda item: (
                    float(item["metrics/accuracy_top1"]), int(item["epoch"])
                ),
            )
            best_epochs.append(int(best["epoch"]))
        except (KeyError, TypeError, ValueError) as error:
            raise SelectionError(f"classifier results are malformed: {path}") from error
    return tuple(best_epochs)


def _dataset_manifest_payload(
    catalog_payload: Mapping[str, Any], catalog_sha256: str, split_sha256: str
) -> dict[str, Any]:
    single_images = sorted(
        (
            {
                "imageKey": str(item["key"]),
                "sha256": str(item["sha256"]),
                "categoryId": int(item["category_id"]),
            }
            for item in catalog_payload["images"]
            if item["source_kind"] == "single_bread"
        ),
        key=lambda item: item["imageKey"],
    )
    mixed_crops = sorted(
        (
            {
                "annotationId": str(item["annotation_id"]),
                "imageKey": str(item["image_key"]),
                "categoryId": int(item["category_id"]),
                "bbox": [float(value) for value in item["bbox"]],
            }
            for item in catalog_payload["annotations"]
        ),
        key=lambda item: item["annotationId"],
    )
    if len(single_images) != 3230 or len(mixed_crops) != 510:
        raise SelectionError(
            "final classifier requires exactly 3230 singles and 510 mixed GT crops"
        )
    return {
        "schemaVersion": 1,
        "catalogSha256": catalog_sha256,
        "splitSha256": split_sha256,
        "singleImages": single_images,
        "mixedGroundTruthCrops": mixed_crops,
        "sampleCounts": {"singleImages": 3230, "mixedGroundTruthCrops": 510},
    }


def _write_json_atomic(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(
        (json.dumps(payload, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    )
    os.replace(temporary, path)


def _materialize_final_classifier_dataset(
    catalog_payload: Mapping[str, Any], dataset_root: Path
) -> None:
    if dataset_root.exists():
        shutil.rmtree(dataset_root)
    labels = {int(item["id"]): item for item in catalog_payload["labels"]}
    class_directories = {
        category_id: _class_directory(label) for category_id, label in labels.items()
    }
    for directory in class_directories.values():
        (dataset_root / "train" / directory).mkdir(parents=True, exist_ok=True)
    images = {str(item["key"]): item for item in catalog_payload["images"]}
    for image in sorted(
        (
            item
            for item in catalog_payload["images"]
            if item["source_kind"] == "single_bread"
        ),
        key=lambda item: str(item["key"]),
    ):
        source = Path(str(image["absolute_path"]))
        if sha256_file(source) != str(image["sha256"]):
            raise SelectionError(f"catalog source sha256 mismatch: {source}")
        suffix = source.suffix.lower() or ".jpg"
        destination = (
            dataset_root
            / "train"
            / class_directories[int(image["category_id"])]
            / f"single_{str(image['sha256'])[:20]}{suffix}"
        )
        shutil.copy2(source, destination)
    checked_mixed_sources: set[str] = set()
    for annotation in sorted(
        catalog_payload["annotations"], key=lambda item: str(item["annotation_id"])
    ):
        image = images[str(annotation["image_key"])]
        source = Path(str(image["absolute_path"]))
        if image["key"] not in checked_mixed_sources:
            if sha256_file(source) != str(image["sha256"]):
                raise SelectionError(f"catalog source sha256 mismatch: {source}")
            checked_mixed_sources.add(str(image["key"]))
        token = "".join(
            character if character.isalnum() else "_"
            for character in str(annotation["annotation_id"])
        )
        destination = (
            dataset_root
            / "train"
            / class_directories[int(annotation["category_id"])]
            / f"mixed_{token}.jpg"
        )
        _write_classifier_crop(source, annotation["bbox"], destination)


def _ensure_classifier_validation_scaffold(dataset_root: Path) -> None:
    """Satisfy Ultralytics' loader while keeping all model selection claims OOF."""

    validation_root = dataset_root / "val"
    if validation_root.exists():
        shutil.rmtree(validation_root)
    class_directories = sorted(
        item for item in (dataset_root / "train").iterdir() if item.is_dir()
    )
    if len(class_directories) != 20:
        raise SelectionError("final classifier dataset must contain 20 classes")
    for class_directory in class_directories:
        sources = sorted(item for item in class_directory.iterdir() if item.is_file())
        if not sources:
            raise SelectionError(
                f"final classifier class is empty: {class_directory.name}"
            )
        destination = validation_root / class_directory.name / sources[0].name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(sources[0], destination)


def _yolo_class() -> Any:
    try:
        from ultralytics import YOLO
    except (ImportError, OSError) as error:
        raise SelectionError(f"could not load Ultralytics for final training: {error}") from error
    return YOLO


def _train_final_classifier(
    dataset_root: Path,
    initial_weights: Path,
    output_root: Path,
    epochs: int,
    yolo_factory: Callable[[str], Any] | None = None,
) -> Path:
    YOLO = yolo_factory or _yolo_class()
    run_root = output_root / "train"
    if run_root.exists():
        shutil.rmtree(run_root)
    result = YOLO(str(initial_weights)).train(
        data=str(dataset_root),
        imgsz=224,
        device=0,
        seed=20260714,
        deterministic=True,
        epochs=epochs,
        patience=0,
        batch=64,
        workers=0,
        val=False,
        project=str(output_root),
        name="train",
        exist_ok=True,
    )
    weights = Path(result.save_dir) / "weights" / "last.pt"
    if not weights.is_file():
        raise SelectionError("final classifier training did not produce last.pt")
    return weights.resolve()


def _publish_model(source: Path, destination: Path) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        prefix=destination.name + ".", suffix=".tmp", dir=destination.parent, delete=False
    ) as stream:
        temporary = Path(stream.name)
    try:
        shutil.copy2(source, temporary)
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            temporary.unlink()
    return destination.resolve()


def _classifier_deployment_path(model_root: Path, weights: Path) -> Path:
    return (
        model_root.resolve()
        / f"bread_classifier_yolov8n_cls_v1_{sha256_file(weights)}.pt"
    )


def _publish_content_addressed_classifier(
    source: Path, model_root: Path
) -> ClassifierPublication:
    destination = _classifier_deployment_path(model_root, source)
    source_hash = sha256_file(source)
    if destination.exists():
        if sha256_file(destination) != source_hash:
            raise SelectionError(
                "existing content-addressed classifier has mismatched bytes"
            )
        return ClassifierPublication(destination.resolve(), False)
    return ClassifierPublication(_publish_model(source, destination), True)


def _prepare_final_classifier(
    config: SelectionConfig,
    catalog_payload: Mapping[str, Any],
    epochs: int,
    progress: Callable[[str], None],
) -> ClassifierPublication:
    final_root = config.output_root.resolve() / "final_classifier"
    dataset_root = final_root / "dataset"
    dataset_manifest_path = final_root / "dataset_manifest.json"
    marker_path = final_root / "completion.json"
    initial_weights = (REPOSITORY_ROOT / "yolov8n-cls.pt").resolve()
    catalog_hash = sha256_file(config.catalog_path)
    split_hash = sha256_file(config.split_path)
    expected_dataset_manifest = _dataset_manifest_payload(
        catalog_payload, catalog_hash, split_hash
    )
    expected_dataset_bytes = (
        json.dumps(expected_dataset_manifest, indent=2, ensure_ascii=False) + "\n"
    ).encode("utf-8")
    expected_dataset_hash = hashlib.sha256(expected_dataset_bytes).hexdigest()
    fingerprint = build_final_classifier_fingerprint(
        catalog_sha256=catalog_hash,
        split_sha256=split_hash,
        dataset_manifest_sha256=expected_dataset_hash,
        initial_weights_path=initial_weights,
        epochs=epochs,
    )
    trained = reusable_final_classifier(marker_path, fingerprint)
    if (
        not dataset_manifest_path.is_file()
        or sha256_file(dataset_manifest_path) != expected_dataset_hash
    ):
        trained = None
    if trained is None:
        progress("classifier phase=materialize-all-data singles=3230 mixed-crops=510")
        _materialize_final_classifier_dataset(catalog_payload, dataset_root)
        _ensure_classifier_validation_scaffold(dataset_root)
        _write_json_atomic(dataset_manifest_path, expected_dataset_manifest)
        if sha256_file(dataset_manifest_path) != expected_dataset_hash:
            raise SelectionError("final classifier dataset manifest hash mismatch")
        progress(f"classifier phase=train-final epochs={epochs} samples=3740")
        trained = _train_final_classifier(
            dataset_root, initial_weights, final_root, epochs
        )
        _write_json_atomic(
            marker_path,
            {
                "schemaVersion": 1,
                "trainingFingerprint": fingerprint,
                "finalWeights": str(trained),
                "finalWeightsSha256": sha256_file(trained),
                "oofClaimsSource": "five_fold_weights_only",
            },
        )
        progress(f"classifier phase=train-final-complete sha256={sha256_file(trained)}")
    else:
        progress(f"classifier phase=reuse-final sha256={sha256_file(trained)}")
    return _publish_content_addressed_classifier(
        trained, config.manifest_path.resolve().parent
    )


def _prepare_selected_detector(
    config: SelectionConfig,
    selected: ModelSelection,
    candidates: Sequence[ModelSelection],
    catalog_payload: Mapping[str, Any],
    progress: Callable[[str], None],
) -> ModelSelection:
    if selected.name == "current_detector":
        return selected
    report_path = config.candidate_root / selected.name / "candidate_report.json"
    payload = _read_json(report_path, "selected detector candidate report")
    epochs = median_best_epoch(tuple(int(item) for item in payload["best_epochs"]))
    progress(f"detector phase=train-final candidate={selected.name} epochs={epochs}")
    dataset = build_detector_all_data(
        catalog_payload, config.output_root / "final_detector_dataset"
    )
    initial = (
        config.manifest_path.parent / "bread_yolov8n_1class_tray_v0_2.pt"
        if selected.name == "current_finetune_real"
        else REPOSITORY_ROOT / "yolov8n.pt"
    )
    model = _yolo_class()(str(initial))
    result = model.train(
        data=str(dataset / "dataset.yaml"),
        imgsz=640,
        device=0,
        seed=20260714,
        deterministic=True,
        workers=0,
        batch=16,
        epochs=epochs,
        patience=0,
        project=str(config.output_root / "final_detector"),
        name="train",
        exist_ok=True,
    )
    trained = Path(result.save_dir) / "weights" / "last.pt"
    deployed = _publish_model(
        trained,
        config.manifest_path.resolve().parent / f"bread_detector_{selected.name}_v1.pt",
    )
    return ModelSelection(
        name=selected.name,
        path=deployed,
        sha256=sha256_file(deployed),
        report=selected.report,
        confidence=selected.confidence,
        iou=selected.iou,
        median_latency_ms=selected.median_latency_ms,
    )


def _none_verifier() -> VerifierDecision:
    return VerifierDecision(
        kind="none",
        metrics=VerifierMetrics(
            kind="none",
            ambiguous_accuracy_gain=0.0,
            review_reduction_at_policy_precision=0.0,
            auto_precision_drop=0.0,
            p50_ms=0.0,
            p95_ms=0.0,
            supported_class_precision={},
        ),
    )


def run_selection(
    config: SelectionConfig, progress: Callable[[str], None] = print
) -> SelectionReport:
    output_root = _guard_output_path(config.output_root)
    manifest_path = _guard_manifest_path(config.manifest_path)
    if output_root.is_relative_to(config.raw_root.resolve()):
        raise SelectionError("selection output cannot be below the raw root")
    if manifest_path.is_relative_to(config.raw_root.resolve()):
        raise SelectionError("pipeline manifest cannot be below the raw root")
    catalog = load_catalog(config.catalog_path)
    if Path(catalog.raw_root).resolve() != config.raw_root.resolve():
        raise SelectionError("raw root must match the catalog raw_root")
    if catalog.labels != tuple(enumerate(CANONICAL_LABELS, start=1)):
        raise SelectionError("catalog labels must match canonical ordered IDs and names")
    catalog_payload = _read_json(config.catalog_path, "bread catalog")
    _validate_catalog_sources(catalog_payload, config.raw_root)
    baseline = _load_baseline(config.baseline_detector_report)
    candidates = _load_candidates(config.candidate_root)
    selected, decision = choose_detector(baseline, candidates)
    progress(
        "detector phase=selection "
        f"selected={selected.name} accepted={decision.accepted} "
        f"failed_gates={','.join(decision.failed_gates) or 'none'}"
    )
    detector = _prepare_selected_detector(
        config, selected, candidates, catalog_payload, progress
    )
    classifier_payload = _read_json(
        config.classifier_root / "classifier_report.json", "classifier OOF report"
    )
    split_payload = _read_json(config.split_path, "bread split")
    _validate_classifier_provenance(
        classifier_payload,
        config.classifier_root,
        catalog_payload,
        split_payload,
    )
    policy_payload = classifier_payload.get("policy")
    deployment_report = classifier_payload.get("deployment_policy_report")
    if not isinstance(policy_payload, dict) or not isinstance(deployment_report, dict):
        raise SelectionError("classifier report is missing policy handoff fields")
    label_policy = LabelPolicy(
        version=str(policy_payload["version"]),
        confidence=float(policy_payload["confidence"]),
        margin=float(policy_payload["margin"]),
        conservative_classes=tuple(
            int(item) for item in policy_payload["conservative_classes"]
        ),
    )
    if label_policy.version != "bread-label-policy-v2":
        raise SelectionError("policyVersion must be bread-label-policy-v2")
    if Decimal(str(deployment_report["precision"])) < CLASSIFIER_PRECISION_FLOOR:
        raise SelectionError(
            "classifier deployment precision is below the approved 0.94 floor"
        )
    classifier_epochs = median_best_epoch(_classifier_best_epochs(config.classifier_root))
    progress(f"classifier phase=selection median-best-epoch={classifier_epochs}")
    classifier_publication = _prepare_final_classifier(
        config, catalog_payload, classifier_epochs, progress
    )
    classifier_path = classifier_publication.path
    classifier = ModelSelection(
        name="final_classifier_all_real",
        path=classifier_path,
        sha256=sha256_file(classifier_path),
        report=deployment_report,
        confidence=label_policy.confidence,
        iou=label_policy.margin,
        median_latency_ms=float(
            classifier_payload.get("latency_ms", {}).get("p50", 0.0)
        ),
    )
    selection = SelectionReport(
        catalog=catalog,
        baseline_detector=baseline,
        detector=detector,
        detector_gate=decision,
        classifier=classifier,
        label_policy=label_policy,
        classifier_policy_report=deployment_report,
        verifier=_none_verifier(),
        synthetic_disabled_reason=SYNTHETIC_DISABLED_REASON,
    )
    manifest = build_manifest(selection)
    audit = _publish_manifest_with_classifier_cleanup(
        manifest_path, manifest, classifier_publication
    )
    output_root.mkdir(parents=True, exist_ok=True)
    _write_json_atomic(
        output_root / "selection_report.json",
        {
            "schemaVersion": 1,
            "detector": {
                "selected": detector.name,
                "file": detector.path.name,
                "candidateAccepted": decision.accepted,
                "failedGates": list(decision.failed_gates),
                "checks": dict(decision.checks),
            },
            "classifier": {
                "selected": classifier.name,
                "file": classifier.path.name,
                "finalTrainingEpochs": classifier_epochs,
                "finalTrainingSamples": 3740,
                "oofClaimsSource": "five_fold_weights_only",
                "precision": float(deployment_report["precision"]),
                "coverage": float(deployment_report["coverage"]),
                "policy": asdict(label_policy),
            },
            "verifier": {"kind": "none"},
            "syntheticDisabledReason": SYNTHETIC_DISABLED_REASON,
            "manifestAudit": audit,
        },
    )
    progress(
        f"manifest phase=audit ok={str(audit['ok']).lower()} "
        f"pipeline={audit['pipelineVersion']} verifier={audit['verifierKind']}"
    )
    return selection


def _selection_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-root", required=True, type=Path)
    parser.add_argument("--catalog", required=True, type=Path)
    parser.add_argument("--split", required=True, type=Path)
    parser.add_argument("--baseline-detector", required=True, type=Path)
    parser.add_argument("--candidate-root", required=True, type=Path)
    parser.add_argument("--classifier-root", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--write-manifest", required=True, type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments and arguments[0] == "audit-handoff":
        parser = argparse.ArgumentParser(description="Audit pipeline manifest handoff")
        parser.add_argument("--manifest", required=True, type=Path)
        parser.add_argument("--output", required=True, type=Path)
        args = parser.parse_args(arguments[1:])
        audit = audit_manifest_contract(args.manifest)
        _write_json_atomic(_guard_output_path(args.output), audit)
        print(json.dumps(audit, indent=2))
        return 0
    args = _selection_parser().parse_args(arguments)
    run_selection(
        SelectionConfig(
            raw_root=args.raw_root,
            catalog_path=args.catalog,
            split_path=args.split,
            baseline_detector_report=args.baseline_detector,
            candidate_root=args.candidate_root,
            classifier_root=args.classifier_root,
            output_root=args.output_root,
            manifest_path=args.write_manifest,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
