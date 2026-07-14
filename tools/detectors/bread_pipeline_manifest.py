"""Load and validate the schema-v1 bread inference pipeline manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from typing import Any, Mapping, Sequence


SCHEMA_VERSION = 1
PIPELINE_VERSION = "bread-pipeline-v1"
POLICY_VERSION = "bread-label-policy-v2"
CLASSIFIER_PRECISION_FLOOR = Decimal("0.94")
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

_TOP_LEVEL_KEYS = {
    "schemaVersion",
    "pipelineVersion",
    "policyVersion",
    "detector",
    "classifier",
    "verifier",
    "quality",
    "labels",
}
_DETECTOR_KEYS = {"file", "sha256", "imgsz", "confidence", "iou"}
_CLASSIFIER_KEYS = {
    "file",
    "sha256",
    "imgsz",
    "acceptConfidence",
    "acceptMargin",
    "conservativeClasses",
    "oofPrecision",
    "oofCoverage",
}
_VERIFIER_KEYS = {
    "kind",
    "file",
    "sha256",
    "scoreThreshold",
    "marginThreshold",
}
_QUALITY_KEYS = {"minBoxSize", "maxAreaRatio", "edgeMarginPx", "duplicateIou"}
_SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")


class ManifestError(RuntimeError):
    """Raised when a pipeline manifest or a required model is invalid."""


@dataclass(frozen=True)
class LabelSpec:
    id: int
    name: str


@dataclass(frozen=True)
class PipelineManifest:
    schema_version: int
    pipeline_version: str
    policy_version: str
    detector: dict[str, Any]
    classifier: dict[str, Any]
    verifier: dict[str, Any]
    quality: dict[str, Any]
    labels: tuple[LabelSpec, ...]


@dataclass(frozen=True)
class ResolvedModels:
    detector_path: Path
    classifier_path: Path | None
    classifier_error: str | None
    verifier_path: Path | None
    verifier_error: str | None


def sha256_file(path: Path) -> str:
    """Return the lowercase SHA-256 digest for a file."""

    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _require_exact_keys(value: Any, expected: set[str], name: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        raise ManifestError(f"manifest {name} fields do not match schema v1")
    return value


def _validate_probability(name: str, value: Any) -> float:
    if type(value) not in (int, float):
        raise ManifestError(f"{name} must be a JSON number")
    number = float(value)
    if not math.isfinite(number) or not 0.0 <= number <= 1.0:
        raise ManifestError(f"{name} must be between 0 and 1")
    return number


def _validate_sha256(kind: str, value: Any) -> str:
    if not isinstance(value, str) or _SHA256_PATTERN.fullmatch(value) is None:
        raise ManifestError(
            f"manifest {kind} sha256 must be 64 lowercase hex characters"
        )
    return value


def _validate_sibling_filename(kind: str, value: Any) -> str:
    if not isinstance(value, str) or not value:
        raise ManifestError(f"manifest {kind} file must be a string")
    filename = Path(value)
    if (
        filename.is_absolute()
        or filename.name != value
        or value in {".", ".."}
        or "/" in value
        or "\\" in value
    ):
        raise ManifestError(f"{kind} file must be a local sibling filename")
    return value


def _validate_labels(value: Any) -> tuple[LabelSpec, ...]:
    if not isinstance(value, list):
        raise ManifestError("labels must contain ordered IDs 1 through 20")
    labels: list[LabelSpec] = []
    for item in value:
        if (
            not isinstance(item, dict)
            or set(item) != {"id", "name"}
            or type(item.get("id")) is not int
            or not isinstance(item.get("name"), str)
        ):
            raise ManifestError("labels must contain ordered IDs 1 through 20")
        labels.append(LabelSpec(id=item["id"], name=item["name"]))
    if tuple(label.id for label in labels) != tuple(range(1, 21)):
        raise ManifestError("labels must contain ordered IDs 1 through 20")
    if tuple(label.name for label in labels) != CANONICAL_LABELS:
        raise ManifestError("labels must use the canonical category names")
    return tuple(labels)


def _validate_detector(value: Any) -> dict[str, Any]:
    detector = _require_exact_keys(value, _DETECTOR_KEYS, "detector")
    _validate_sibling_filename("detector", detector["file"])
    _validate_sha256("detector", detector["sha256"])
    if type(detector["imgsz"]) is not int or detector["imgsz"] != 640:
        raise ManifestError("manifest detector imgsz must be integer 640")
    _validate_probability("detector confidence", detector["confidence"])
    _validate_probability("detector iou", detector["iou"])
    return dict(detector)


def _validate_classifier(value: Any) -> dict[str, Any]:
    classifier = _require_exact_keys(value, _CLASSIFIER_KEYS, "classifier")
    filename = _validate_sibling_filename("classifier", classifier["file"])
    digest = _validate_sha256("classifier", classifier["sha256"])
    expected_filename = f"bread_classifier_yolov8n_cls_v1_{digest}.pt"
    if filename != expected_filename:
        raise ManifestError(
            "classifier file must use the exact content-addressed sha256 name"
        )
    if type(classifier["imgsz"]) is not int or classifier["imgsz"] != 224:
        raise ManifestError("manifest classifier imgsz must be integer 224")
    for name, field in (
        ("acceptConfidence", "acceptConfidence"),
        ("acceptMargin", "acceptMargin"),
        ("oofPrecision", "oofPrecision"),
        ("oofCoverage", "oofCoverage"),
    ):
        _validate_probability(name, classifier[field])
    if Decimal(str(classifier["oofPrecision"])) < CLASSIFIER_PRECISION_FLOOR:
        raise ManifestError("classifier precision is below the approved 0.94 floor")
    conservative = classifier["conservativeClasses"]
    if (
        not isinstance(conservative, list)
        or any(type(item) is not int for item in conservative)
        or conservative != sorted(set(conservative))
        or any(item not in range(1, 21) for item in conservative)
    ):
        raise ManifestError(
            "conservativeClasses must be unique ordered IDs 1 through 20"
        )
    return dict(classifier)


def _validate_verifier(value: Any) -> dict[str, Any]:
    verifier = _require_exact_keys(value, _VERIFIER_KEYS, "verifier")
    kind = verifier["kind"]
    if not isinstance(kind, str) or not kind:
        raise ManifestError("manifest verifier kind must be a non-empty string")
    if kind == "none":
        expected = {
            "kind": "none",
            "file": None,
            "sha256": None,
            "scoreThreshold": None,
            "marginThreshold": None,
        }
        if verifier != expected:
            raise ManifestError(
                "verifier kind none cannot reference files or thresholds"
            )
    else:
        _validate_sibling_filename("verifier", verifier["file"])
        _validate_sha256("verifier", verifier["sha256"])
        _validate_probability("verifier scoreThreshold", verifier["scoreThreshold"])
        _validate_probability("verifier marginThreshold", verifier["marginThreshold"])
    return dict(verifier)


def _validate_quality(value: Any) -> dict[str, Any]:
    quality = _require_exact_keys(value, _QUALITY_KEYS, "quality")
    if type(quality["minBoxSize"]) is not int or quality["minBoxSize"] != 45:
        raise ManifestError("quality minBoxSize must be integer 45")
    if type(quality["edgeMarginPx"]) is not int or quality["edgeMarginPx"] != 2:
        raise ManifestError("quality edgeMarginPx must be integer 2")
    if type(quality["maxAreaRatio"]) is not float or quality["maxAreaRatio"] != 0.38:
        raise ManifestError("quality maxAreaRatio must be JSON float 0.38")
    if type(quality["duplicateIou"]) is not float or quality["duplicateIou"] != 0.95:
        raise ManifestError("quality duplicateIou must be JSON float 0.95")
    return dict(quality)


def load_pipeline_manifest(path: Path) -> PipelineManifest:
    """Read a pipeline manifest and validate the complete schema-v1 contract."""

    try:
        payload = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ManifestError(f"could not read pipeline manifest: {path}") from error
    if not isinstance(payload, dict) or set(payload) != _TOP_LEVEL_KEYS:
        raise ManifestError("manifest top-level fields do not match schema v1")
    if type(payload["schemaVersion"]) is not int or payload["schemaVersion"] != 1:
        raise ManifestError("manifest schemaVersion must be integer 1")
    if (
        type(payload["pipelineVersion"]) is not str
        or payload["pipelineVersion"] != PIPELINE_VERSION
    ):
        raise ManifestError(f"manifest pipelineVersion must be {PIPELINE_VERSION}")
    if (
        type(payload["policyVersion"]) is not str
        or payload["policyVersion"] != POLICY_VERSION
    ):
        raise ManifestError(f"manifest policyVersion must be {POLICY_VERSION}")

    return PipelineManifest(
        schema_version=SCHEMA_VERSION,
        pipeline_version=payload["pipelineVersion"],
        policy_version=payload["policyVersion"],
        detector=_validate_detector(payload["detector"]),
        classifier=_validate_classifier(payload["classifier"]),
        verifier=_validate_verifier(payload["verifier"]),
        quality=_validate_quality(payload["quality"]),
        labels=_validate_labels(payload["labels"]),
    )


def _resolve_and_hash(
    manifest_directory: Path, kind: str, specification: Mapping[str, Any]
) -> Path:
    candidate = manifest_directory / specification["file"]
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as error:
        raise ManifestError(f"{kind} model does not exist: {candidate}") from error
    if resolved.parent != manifest_directory or not resolved.is_file():
        raise ManifestError(f"{kind} model must be a sibling file: {candidate}")
    try:
        actual_hash = sha256_file(resolved)
    except OSError as error:
        raise ManifestError(f"could not read {kind} model: {resolved}") from error
    if actual_hash != specification["sha256"]:
        raise ManifestError(f"{kind} sha256 mismatch: {resolved}")
    return resolved


def resolve_model_paths(
    manifest_path: Path, manifest: PipelineManifest
) -> ResolvedModels:
    """Resolve sibling weights and apply required/optional stage failure policy."""

    manifest_directory = Path(manifest_path).resolve().parent
    detector_path = _resolve_and_hash(
        manifest_directory, "detector", manifest.detector
    )

    classifier_path: Path | None = None
    classifier_error: str | None = None
    try:
        classifier_path = _resolve_and_hash(
            manifest_directory, "classifier", manifest.classifier
        )
    except ManifestError as error:
        classifier_error = str(error)

    verifier_path: Path | None = None
    verifier_error: str | None = None
    if manifest.verifier["kind"] != "none":
        try:
            verifier_path = _resolve_and_hash(
                manifest_directory, "verifier", manifest.verifier
            )
        except ManifestError as error:
            verifier_error = str(error)

    return ResolvedModels(
        detector_path=detector_path,
        classifier_path=classifier_path,
        classifier_error=classifier_error,
        verifier_path=verifier_path,
        verifier_error=verifier_error,
    )


def _validation_summary(
    manifest: PipelineManifest, resolved: ResolvedModels
) -> dict[str, Any]:
    return {
        "ok": True,
        "schemaVersion": manifest.schema_version,
        "pipelineVersion": manifest.pipeline_version,
        "policyVersion": manifest.policy_version,
        "labelIds": [label.id for label in manifest.labels],
        "detector": {
            "available": True,
            "path": str(resolved.detector_path),
        },
        "classifier": {
            "available": resolved.classifier_path is not None,
            "path": (
                str(resolved.classifier_path)
                if resolved.classifier_path is not None
                else None
            ),
            "error": resolved.classifier_error,
        },
        "verifier": {
            "kind": manifest.verifier["kind"],
            "available": resolved.verifier_path is not None,
            "path": (
                str(resolved.verifier_path)
                if resolved.verifier_path is not None
                else None
            ),
            "error": resolved.verifier_error,
        },
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    arguments = parser.parse_args(argv)
    try:
        manifest = load_pipeline_manifest(arguments.manifest)
        resolved = resolve_model_paths(arguments.manifest, manifest)
    except ManifestError as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False))
        return 1
    print(json.dumps(_validation_summary(manifest, resolved), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
