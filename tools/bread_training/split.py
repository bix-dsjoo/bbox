"""Build deterministic, leakage-safe bread model-selection folds."""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

import cv2
import numpy as np

from tools.bread_training.audit import AuditReport, audit_catalog
from tools.bread_training.catalog import (
    MIXED_DIRECTORY_NAMES,
    Catalog,
    CatalogAnnotation,
    CatalogImage,
)


FOLD_SIZES = (17, 17, 17, 16, 16)
DEFAULT_SEED = 20260714


class SplitError(ValueError):
    """The catalog cannot be assigned without violating the split contract."""


class LeakageError(SplitError):
    """Derived data provenance overlaps a held-out mixed scene."""


@dataclass(frozen=True)
class DerivedRecord:
    output_key: str
    source_key: str
    fold: int


@dataclass(frozen=True)
class MultilabelItem:
    key: str
    source_group: str
    labels: frozenset[int]


@dataclass
class FoldState:
    index: int
    capacity: int
    size: int = 0
    date_counts: Counter[str] = field(default_factory=Counter)
    label_counts: Counter[int] = field(default_factory=Counter)

    def add(self, item: MultilabelItem) -> None:
        self.size += 1
        self.date_counts[item.source_group] += 1
        self.label_counts.update(item.labels)


def annotation_labels(catalog: Catalog, image_key: str) -> frozenset[int]:
    return frozenset(
        annotation.category_id
        for annotation in catalog.annotations
        if annotation.image_key == image_key
    )


def stable_seed_key(value: str, seed: int) -> str:
    return hashlib.sha256(f"{seed}:{value}".encode("utf-8")).hexdigest()


def build_multilabel_items(catalog: Catalog) -> tuple[MultilabelItem, ...]:
    labels_by_image: dict[str, set[int]] = defaultdict(set)
    for annotation in catalog.annotations:
        labels_by_image[annotation.image_key].add(annotation.category_id)
    return tuple(
        MultilabelItem(
            key=image.key,
            source_group=image.source_group,
            labels=frozenset(labels_by_image[image.key]),
        )
        for image in catalog.images
        if image.source_kind == "mixed_scene"
    )


def _date_quotas(
    items: Sequence[MultilabelItem], capacities: Sequence[int], seed: int
) -> dict[str, tuple[int, ...]]:
    folds = len(capacities)
    date_totals = Counter(item.source_group for item in items)
    quotas = {
        source_group: [count // folds] * folds
        for source_group, count in sorted(date_totals.items())
    }
    remaining = [
        capacity - sum(quotas[group][fold] for group in quotas)
        for fold, capacity in enumerate(capacities)
    ]
    if any(value < 0 for value in remaining):
        raise SplitError("Date baselines exceed fold capacities")

    for source_group, count in sorted(date_totals.items()):
        remainder = count % folds
        candidates = sorted(
            range(folds),
            key=lambda fold: (
                -remaining[fold],
                stable_seed_key(f"date:{source_group}:{fold}", seed),
                fold,
            ),
        )
        selected = [fold for fold in candidates if remaining[fold] > 0][:remainder]
        if len(selected) != remainder:
            raise SplitError("Could not fit balanced date quotas into fold capacities")
        for fold in selected:
            quotas[source_group][fold] += 1
            remaining[fold] -= 1

    if any(remaining):
        raise SplitError("Date quotas do not fill every fold capacity")
    return {group: tuple(values) for group, values in quotas.items()}


def _assignment_cost(
    state: FoldState,
    item: MultilabelItem,
    date_quotas: Mapping[str, Sequence[int]],
    label_targets: Mapping[int, float],
) -> tuple[bool, float, int, int]:
    quota = date_quotas[item.source_group][state.index]
    date_full = state.date_counts[item.source_group] >= quota
    label_cost = sum(
        ((state.label_counts[label] + 1) - label_targets[label]) ** 2
        - (state.label_counts[label] - label_targets[label]) ** 2
        for label in item.labels
    )
    return (date_full or state.size >= state.capacity, label_cost, state.size, state.index)


def assign_folds(
    catalog: Catalog, folds: int = 5, seed: int = DEFAULT_SEED
) -> dict[str, int]:
    """Assign all 83 real mixed scenes to one deterministic OOF fold."""

    if folds != len(FOLD_SIZES):
        raise SplitError(f"This dataset requires exactly {len(FOLD_SIZES)} folds")
    report = audit_catalog(catalog)
    if not report.ok:
        codes = ", ".join(sorted({issue.code for issue in report.issues}))
        raise SplitError(f"Catalog audit failed: {codes}")

    mixed = build_multilabel_items(catalog)
    if len(mixed) != sum(FOLD_SIZES):
        raise SplitError(
            f"Expected {sum(FOLD_SIZES)} mixed images, found {len(mixed)}"
        )
    if len({item.key for item in mixed}) != len(mixed):
        raise SplitError("Mixed image keys must be unique")
    source_groups = {item.source_group for item in mixed}
    if source_groups != set(MIXED_DIRECTORY_NAMES):
        raise SplitError(
            "Mixed images must use the four canonical dated source groups"
        )
    if any(not item.labels for item in mixed):
        raise SplitError("Every mixed image must have at least one annotation label")

    label_totals = Counter(label for item in mixed for label in item.labels)
    label_targets = {label: count / folds for label, count in label_totals.items()}
    rarity = {
        label: 1.0 / count for label, count in label_totals.items() if count
    }
    ordered = sorted(
        mixed,
        key=lambda item: (
            -sum(rarity[label] for label in item.labels),
            -len(item.labels),
            stable_seed_key(item.key, seed),
            item.key,
        ),
    )
    date_quotas = _date_quotas(mixed, FOLD_SIZES, seed)
    states = [FoldState(index, capacity) for index, capacity in enumerate(FOLD_SIZES)]
    result: dict[str, int] = {}
    for item in ordered:
        chosen = min(
            states,
            key=lambda state: _assignment_cost(
                state, item, date_quotas, label_targets
            ),
        )
        if _assignment_cost(chosen, item, date_quotas, label_targets)[0]:
            raise SplitError(f"No valid fold remains for {item.key}")
        chosen.add(item)
        result[item.key] = chosen.index

    _improve_label_balance(result, mixed, states, seed)
    _validate_fold_assignment(result, mixed, states, date_quotas)
    return dict(sorted(result.items()))


def _improve_label_balance(
    assignments: dict[str, int],
    items: Sequence[MultilabelItem],
    states: Sequence[FoldState],
    seed: int,
) -> None:
    items_by_key = {item.key: item for item in items}
    keys = sorted(assignments)
    while True:
        candidates: list[tuple[int, str, str]] = []
        for offset, left_key in enumerate(keys):
            left = items_by_key[left_key]
            left_fold = assignments[left_key]
            for right_key in keys[offset + 1 :]:
                right = items_by_key[right_key]
                right_fold = assignments[right_key]
                if left_fold == right_fold or left.source_group != right.source_group:
                    continue
                labels = left.labels | right.labels
                before = sum(
                    states[left_fold].label_counts[label] ** 2
                    + states[right_fold].label_counts[label] ** 2
                    for label in labels
                )
                after = sum(
                    (
                        states[left_fold].label_counts[label]
                        - (label in left.labels)
                        + (label in right.labels)
                    )
                    ** 2
                    + (
                        states[right_fold].label_counts[label]
                        - (label in right.labels)
                        + (label in left.labels)
                    )
                    ** 2
                    for label in labels
                )
                improvement = before - after
                if improvement > 0:
                    candidates.append((improvement, left_key, right_key))
        if not candidates:
            return
        _, left_key, right_key = min(
            candidates,
            key=lambda candidate: (
                -candidate[0],
                stable_seed_key(f"swap:{candidate[1]}:{candidate[2]}", seed),
                candidate[1],
                candidate[2],
            ),
        )
        left = items_by_key[left_key]
        right = items_by_key[right_key]
        left_fold = assignments[left_key]
        right_fold = assignments[right_key]
        states[left_fold].label_counts.subtract(left.labels)
        states[right_fold].label_counts.update(left.labels)
        states[right_fold].label_counts.subtract(right.labels)
        states[left_fold].label_counts.update(right.labels)
        assignments[left_key], assignments[right_key] = right_fold, left_fold


def _validate_fold_assignment(
    assignments: Mapping[str, int],
    items: Sequence[MultilabelItem],
    states: Sequence[FoldState],
    date_quotas: Mapping[str, Sequence[int]],
) -> None:
    expected_keys = {item.key for item in items}
    if set(assignments) != expected_keys:
        raise SplitError("Every mixed image must receive exactly one assignment")
    actual_sizes = tuple(state.size for state in states)
    if actual_sizes != FOLD_SIZES:
        raise SplitError(f"Unexpected fold sizes: {actual_sizes}")
    for source_group, quotas in date_quotas.items():
        actual = tuple(state.date_counts[source_group] for state in states)
        if actual != tuple(quotas):
            raise SplitError(
                f"Date group {source_group} is not balanced: {actual} != {tuple(quotas)}"
            )


def _perceptual_hash(image: CatalogImage) -> int:
    path = Path(image.absolute_path)
    try:
        encoded = np.fromfile(path, dtype=np.uint8)
    except OSError as error:
        raise SplitError(f"Could not read single-product image: {image.key}") from error
    decoded = cv2.imdecode(encoded, cv2.IMREAD_GRAYSCALE)
    if decoded is None:
        raise SplitError(f"Could not decode single-product image: {image.key}")
    resized = cv2.resize(decoded, (32, 32), interpolation=cv2.INTER_AREA)
    frequencies = cv2.dct(np.float32(resized))[:8, :8]
    median = float(np.median(frequencies.flatten()[1:]))
    value = 0
    for bit in (frequencies > median).flatten():
        value = (value << 1) | int(bit)
    return value


def group_single_product_images(
    catalog: Catalog, max_hamming_distance: int = 4
) -> tuple[tuple[str, ...], ...]:
    """Cluster same-folder single images by connected pHash distance."""

    if max_hamming_distance < 0:
        raise SplitError("Perceptual-hash distance must be non-negative")
    images = sorted(
        (image for image in catalog.images if image.source_kind == "single_bread"),
        key=lambda image: (image.source_group, image.key),
    )
    parents = list(range(len(images)))

    def find(index: int) -> int:
        while parents[index] != index:
            parents[index] = parents[parents[index]]
            index = parents[index]
        return index

    def union(left: int, right: int) -> None:
        left_root = find(left)
        right_root = find(right)
        if left_root != right_root:
            parents[max(left_root, right_root)] = min(left_root, right_root)

    hashes = [_perceptual_hash(image) for image in images]
    by_source: dict[str, list[int]] = defaultdict(list)
    for index, image in enumerate(images):
        by_source[image.source_group].append(index)
    for indexes in by_source.values():
        for offset, left in enumerate(indexes):
            for right in indexes[offset + 1 :]:
                if (hashes[left] ^ hashes[right]).bit_count() <= max_hamming_distance:
                    union(left, right)

    grouped: dict[int, list[str]] = defaultdict(list)
    for index, image in enumerate(images):
        grouped[find(index)].append(image.key)
    return tuple(
        sorted(
            (tuple(sorted(keys)) for keys in grouped.values()),
            key=lambda group: group[0],
        )
    )


def assign_single_product_folds(
    catalog: Catalog, folds: int = 5, seed: int = DEFAULT_SEED
) -> dict[str, int]:
    if folds <= 1:
        raise SplitError("At least two auxiliary folds are required")
    groups = group_single_product_images(catalog)
    return _assign_single_product_groups(catalog, groups, folds, seed)


def _assign_single_product_groups(
    catalog: Catalog,
    groups: Sequence[Sequence[str]],
    folds: int,
    seed: int,
) -> dict[str, int]:
    images_by_key = {image.key: image for image in catalog.images}
    source_counts: dict[str, Counter[int]] = defaultdict(Counter)
    total_counts: Counter[int] = Counter()
    result: dict[str, int] = {}
    ordered = sorted(
        groups,
        key=lambda group: (
            -len(group),
            stable_seed_key(group[0], seed),
            group[0],
        ),
    )
    for group in ordered:
        source_group = images_by_key[group[0]].source_group
        if any(images_by_key[key].source_group != source_group for key in group):
            raise SplitError("A near-duplicate group crossed source folders")
        fold = min(
            range(folds),
            key=lambda candidate: (
                source_counts[source_group][candidate],
                total_counts[candidate],
                stable_seed_key(f"aux:{group[0]}:{candidate}", seed),
                candidate,
            ),
        )
        for key in group:
            result[key] = fold
        source_counts[source_group][fold] += len(group)
        total_counts[fold] += len(group)
    return dict(sorted(result.items()))


_MISSING = object()


def _validated_source_key(value: object, field_name: str) -> str:
    if not isinstance(value, str) or not value.strip() or value != value.strip():
        raise LeakageError(f"Derived record has malformed {field_name}")
    return value


def _record_sources(record: object) -> tuple[str, ...]:
    sources: list[str] = []
    source_key = getattr(record, "source_key", _MISSING)
    if source_key is not _MISSING:
        sources.append(_validated_source_key(source_key, "source_key"))
    source_keys = getattr(record, "source_keys", _MISSING)
    if source_keys is not _MISSING:
        if not isinstance(source_keys, (tuple, list)):
            raise LeakageError("Derived record has malformed source_keys")
        sources.extend(
            _validated_source_key(value, "source_keys entry")
            for value in source_keys
        )
    background_key = getattr(record, "background_key", _MISSING)
    if background_key is not _MISSING:
        sources.append(_validated_source_key(background_key, "background_key"))
    return tuple(dict.fromkeys(sources))


def assert_no_mixed_scene_leakage(
    assignments: Mapping[str, int], derived_records: Iterable[object]
) -> None:
    """Reject held-out or unknown mixed-scene provenance for derived data."""

    for record in derived_records:
        fold = getattr(record, "fold", None)
        if type(fold) is not int:
            raise LeakageError("Derived record is missing an integer fold")
        sources = _record_sources(record)
        if not sources:
            raise LeakageError("Derived record is missing source provenance")
        for source_key in sources:
            if not source_key.startswith("Test_"):
                continue
            if source_key not in assignments:
                raise LeakageError(f"Unknown mixed-scene source: {source_key}")
            if assignments[source_key] == fold:
                raise LeakageError(
                    f"Held-out mixed scene {source_key} is a source for fold {fold}"
                )


def _require_json_int(value: Any, field: str) -> int:
    if type(value) is not int:
        raise SplitError(f"{field} must be a JSON integer")
    return value


def _require_json_bbox(value: Any) -> tuple[float, float, float, float]:
    if (
        not isinstance(value, list)
        or len(value) != 4
        or any(type(coordinate) not in (int, float) for coordinate in value)
    ):
        raise SplitError(
            "annotation bbox must be a four-number JSON array without booleans"
        )
    return tuple(float(coordinate) for coordinate in value)


def load_catalog(path: Path) -> Catalog:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SplitError(f"Could not read catalog JSON: {path}") from error
    try:
        labels = tuple(
            (_require_json_int(item["id"], "label id"), str(item["name"]))
            for item in payload["labels"]
        )
        images = tuple(
            CatalogImage(
                key=str(item["key"]),
                absolute_path=str(item["absolute_path"]),
                sha256=str(item["sha256"]),
                width=_require_json_int(item["width"], "image width"),
                height=_require_json_int(item["height"], "image height"),
                source_kind=str(item["source_kind"]),
                source_group=str(item["source_group"]),
                category_id=(
                    None
                    if item.get("category_id") is None
                    else _require_json_int(item["category_id"], "image category id")
                ),
                category_name=(
                    None
                    if item.get("category_name") is None
                    else str(item["category_name"])
                ),
            )
            for item in payload["images"]
        )
        annotations = tuple(
            CatalogAnnotation(
                annotation_id=str(item["annotation_id"]),
                image_key=str(item["image_key"]),
                category_id=_require_json_int(
                    item["category_id"], "annotation category id"
                ),
                category_name=str(item["category_name"]),
                bbox=_require_json_bbox(item["bbox"]),
            )
            for item in payload["annotations"]
        )
        raw_root = str(payload["raw_root"])
    except (KeyError, TypeError, ValueError) as error:
        raise SplitError(f"Malformed catalog JSON: {path}") from error
    return Catalog(labels, images, annotations, raw_root)


def _fold_summary(
    catalog: Catalog, assignments: Mapping[str, int], folds: int
) -> list[dict[str, Any]]:
    images_by_key = {image.key: image for image in catalog.images}
    labels_by_key = {
        key: annotation_labels(catalog, key) for key in assignments
    }
    rows = []
    for fold in range(folds):
        keys = [key for key, assigned_fold in assignments.items() if assigned_fold == fold]
        dates = Counter(images_by_key[key].source_group for key in keys)
        labels = Counter(label for key in keys for label in labels_by_key[key])
        rows.append(
            {
                "fold": fold,
                "size": len(keys),
                "dates": dict(sorted(dates.items())),
                "labels": {str(key): value for key, value in sorted(labels.items())},
            }
        )
    return rows


def _write_json_under(
    path: Path, payload: Any, required_directory: str, raw_root: Path
) -> None:
    output = path.resolve()
    resolved_raw_root = raw_root.resolve()
    try:
        output.relative_to(resolved_raw_root)
    except ValueError:
        pass
    else:
        raise SplitError(f"Refusing to write under catalog raw root: {output}")
    if required_directory not in output.parts:
        raise SplitError(
            f"Refusing to write outside an ignored {required_directory}/ directory: {output}"
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def build_split_payload(
    catalog: Catalog, folds: int = 5, seed: int = DEFAULT_SEED
) -> dict[str, Any]:
    mixed_assignments = assign_folds(catalog, folds=folds, seed=seed)
    single_groups = group_single_product_images(catalog)
    single_assignments = _assign_single_product_groups(
        catalog, single_groups, folds, seed
    )
    groups_by_fold: dict[int, list[list[str]]] = defaultdict(list)
    for group in single_groups:
        groups_by_fold[single_assignments[group[0]]].append(list(group))
    return {
        "schema_version": 1,
        "seed": seed,
        "folds": folds,
        "mixed_assignments": mixed_assignments,
        "single_product_assignments": single_assignments,
        "single_product_groups": [
            {"fold": fold, "keys": keys}
            for fold in range(folds)
            for keys in groups_by_fold[fold]
        ],
        "fold_summary": _fold_summary(catalog, mixed_assignments, folds),
    }


def _parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", required=True, type=Path)
    parser.add_argument("--audit-output", required=True, type=Path)
    parser.add_argument("--split-output", required=True, type=Path)
    parser.add_argument("--folds", type=int, default=5)
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    args = _parse_args(argv)
    catalog = load_catalog(args.catalog)
    report: AuditReport = audit_catalog(catalog)
    raw_root = Path(catalog.raw_root)
    _write_json_under(args.audit_output, report.to_json(), "outputs", raw_root)
    if not report.ok:
        codes = ", ".join(sorted({issue.code for issue in report.issues}))
        raise SplitError(f"Catalog audit failed: {codes}")
    payload = build_split_payload(catalog, folds=args.folds, seed=args.seed)
    _write_json_under(args.split_output, payload, "datasets", raw_root)
    for row in payload["fold_summary"]:
        print(
            f"fold={row['fold']} size={row['size']} "
            f"dates={json.dumps(row['dates'], sort_keys=True)} "
            f"labels={json.dumps(row['labels'], sort_keys=True)}"
        )
    print(
        f"audit={args.audit_output.resolve()} split={args.split_output.resolve()} "
        f"single_images={len(payload['single_product_assignments'])}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
