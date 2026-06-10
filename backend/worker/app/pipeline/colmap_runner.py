"""
colmap_runner.py
~~~~~~~~~~~~~~~~
Drives COLMAP to extract camera poses from an unposed image set, then
converts the sparse reconstruction to the Nerfstudio ``transforms.json``
format using ``ns-process-data``.

Pipeline
--------
1.  ``colmap feature_extractor``   – detect SIFT keypoints in every image.
2.  ``colmap exhaustive_matcher``  – match features between all image pairs.
3.  ``colmap mapper``              – triangulate a sparse 3-D model and
                                     recover camera extrinsics / intrinsics.
4.  ``ns-process-data colmap``     – convert the COLMAP sparse model to a
                                     ``transforms.json`` file that Nerfstudio
                                     can consume directly.

All sub-processes are run with ``check=True``; a non-zero exit code raises
``RuntimeError`` with the captured stderr for easy debugging.
"""

from __future__ import annotations

import logging
import os
import subprocess
from pathlib import Path
from typing import Callable, Optional

logger = logging.getLogger(__name__)

# GPU SIFT requires a CUDA-enabled COLMAP build (the Ubuntu apt package is
# CPU-only) and an OpenGL context, which headless containers lack. Default to
# CPU so the pipeline works out of the box; set COLMAP_USE_GPU=1 only when
# running a CUDA build of COLMAP.
_USE_GPU: str = "1" if os.environ.get("COLMAP_USE_GPU", "0") == "1" else "0"
_GPU_INDEX: str = os.environ.get("COLMAP_GPU_INDEX", "0")

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def run_colmap(
    images_dir: str,
    work_dir: str,
    update_progress: Optional[Callable[[float, str], None]] = None,
) -> str:
    """
    Run the full COLMAP → Nerfstudio conversion pipeline.

    Parameters
    ----------
    images_dir:
        Directory containing the raw image frames.
    work_dir:
        Scratch directory for COLMAP databases, sparse models, and the
        final ``transforms.json``.
    update_progress:
        Optional ``(fraction, message)`` callback.  *fraction* is in
        ``[0.0, 1.0]`` and scoped to this function's contribution.

    Returns
    -------
    str
        Absolute path to the generated ``transforms.json``.
    """

    def _progress(f: float, msg: str) -> None:
        if update_progress is not None:
            update_progress(f, msg)
        logger.info("[colmap] %.0f%%  %s", f * 100, msg)

    images_path = Path(images_dir).resolve()
    work_path = Path(work_dir).resolve()

    db_path = work_path / "colmap.db"
    sparse_dir = work_path / "sparse"
    sparse_dir.mkdir(parents=True, exist_ok=True)
    ns_data_dir = work_path / "nerfstudio_data"
    ns_data_dir.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------
    # Step 1 – Feature extraction
    # ------------------------------------------------------------------
    _progress(0.00, "COLMAP: extracting features")
    _run(
        [
            "colmap",
            "feature_extractor",
            "--database_path", str(db_path),
            "--image_path", str(images_path),
            "--ImageReader.camera_model", "OPENCV",
            "--ImageReader.single_camera", "1",
            "--SiftExtraction.use_gpu", _USE_GPU,
            "--SiftExtraction.gpu_index", _GPU_INDEX,
            "--SiftExtraction.max_image_size", "3200",
            "--SiftExtraction.max_num_features", "8192",
        ],
        step="feature_extractor",
    )

    # ------------------------------------------------------------------
    # Step 2 – Feature matching
    # ------------------------------------------------------------------
    _progress(0.30, "COLMAP: matching features (exhaustive)")
    _run(
        [
            "colmap",
            "exhaustive_matcher",
            "--database_path", str(db_path),
            "--SiftMatching.use_gpu", _USE_GPU,
            "--SiftMatching.gpu_index", _GPU_INDEX,
        ],
        step="exhaustive_matcher",
    )

    # ------------------------------------------------------------------
    # Step 3 – Sparse reconstruction (mapper)
    # ------------------------------------------------------------------
    _progress(0.55, "COLMAP: running mapper")
    _run(
        [
            "colmap",
            "mapper",
            "--database_path", str(db_path),
            "--image_path", str(images_path),
            "--output_path", str(sparse_dir),
            "--Mapper.num_threads", "8",
            "--Mapper.init_min_tri_angle", "4",
        ],
        step="mapper",
    )

    # Mapper creates numbered sub-directories (0/, 1/, …) for each
    # connected component.  Use the first (largest) one.
    sparse_model_dir = _find_first_sparse_model(sparse_dir)
    logger.info("[colmap] Using sparse model at %s", sparse_model_dir)

    # ------------------------------------------------------------------
    # Step 4 – Convert to Nerfstudio transforms.json
    # ------------------------------------------------------------------
    _progress(0.80, "Converting COLMAP output to Nerfstudio format")
    _run(
        [
            "ns-process-data",
            "images",
            "--data", str(images_path),
            "--output-dir", str(ns_data_dir),
            "--skip-colmap",               # we already ran COLMAP ourselves
            "--colmap-model-path", str(sparse_model_dir),
        ],
        step="ns-process-data",
    )

    transforms_json = ns_data_dir / "transforms.json"
    if not transforms_json.exists():
        # Some versions of ns-process-data write to a sub-directory.
        candidates = list(ns_data_dir.rglob("transforms.json"))
        if not candidates:
            raise RuntimeError(
                "ns-process-data did not produce a transforms.json file in "
                f"{ns_data_dir}.  Check the ns-process-data logs above."
            )
        transforms_json = candidates[0]

    _progress(1.0, "COLMAP pipeline complete")
    logger.info("[colmap] transforms.json at %s", transforms_json)
    return str(transforms_json)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _run(cmd: list[str], *, step: str) -> subprocess.CompletedProcess:
    """
    Execute *cmd* as a subprocess, streaming stdout/stderr to the logger.
    Raises ``RuntimeError`` on non-zero exit.
    """
    logger.info("[colmap:%s] Running: %s", step, " ".join(cmd))
    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.stdout:
        for line in result.stdout.splitlines():
            logger.debug("[colmap:%s] %s", step, line)

    if result.returncode != 0:
        # Log the tail of the output so it surfaces in Celery logs.
        tail = "\n".join((result.stdout or "").splitlines()[-40:])
        raise RuntimeError(
            f"COLMAP step '{step}' failed with exit code {result.returncode}.\n"
            f"Last output:\n{tail}"
        )
    return result


def _find_first_sparse_model(sparse_dir: Path) -> Path:
    """
    Return the sub-directory of the largest connected component produced
    by ``colmap mapper``.  The mapper numbers them 0, 1, 2 … with 0 being
    the one with the most registered images.
    """
    numbered = sorted(
        (d for d in sparse_dir.iterdir() if d.is_dir() and d.name.isdigit()),
        key=lambda d: int(d.name),
    )
    if not numbered:
        raise RuntimeError(
            f"COLMAP mapper produced no sparse model in {sparse_dir}.  "
            "This usually means there are too few images or the images lack "
            "sufficient visual overlap."
        )
    return numbered[0]
