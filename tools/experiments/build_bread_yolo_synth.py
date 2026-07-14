"""Compatibility entrypoint for the leakage-safe bread synthetic builder."""

from tools.bread_training.synthetic import (
    SyntheticQualityError,
    SyntheticRecord,
    balanced_batch_kinds,
    build_synthetic_fold,
    choose_background,
    main,
    mask_bbox,
)


__all__ = [
    "SyntheticQualityError",
    "SyntheticRecord",
    "balanced_batch_kinds",
    "build_synthetic_fold",
    "choose_background",
    "main",
    "mask_bbox",
]


if __name__ == "__main__":
    raise SystemExit(main())
