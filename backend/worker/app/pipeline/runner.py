"""
runner.py
~~~~~~~~~
Top-level orchestrator for the iPhone scan → Gaussian Splat pipeline.

Steps
-----
1.  Extract the uploaded ZIP archive to a temporary work directory.
2.  Locate the images sub-directory inside the archive.
3.  Check whether the archive already contains a ``transforms.json`` (produced
    by ARKit / Record3D / PolyCam etc.).
4a. If ``transforms.json`` **is** present: validate / copy it so that
    Nerfstudio can consume it directly.
4b. If ``transforms.json`` **is absent**: run COLMAP via ``colmap_runner`` to
    produce camera poses, then convert them with ``ns-process-data``.
5.  Train a splatfacto model with Nerfstudio.
6.  Copy the exported ``.ply`` to the shared results directory.
7.  Call ``update_progress(1.0, "Complete")`` and return the result path.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import zipfile
from pathlib import Path
from typing import Callable

from . import colmap_runner, nerfstudio_runner, video_processor

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

RESULTS_DIR: str = os.environ.get("RESULTS_DIR", "/data/results")
WORK_BASE_DIR: str = os.environ.get("WORK_DIR", "/data/work")

# Directories commonly used as image roots inside ARKit ZIP archives.
_IMAGE_DIR_CANDIDATES: tuple[str, ...] = (
    "images",
    "frames",
    "rgb",
    "Photos",
    "photos",
    "color",
)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def run_pipeline(
    job_id: str,
    upload_path: str,
    update_progress: Callable[[float, str], None],
) -> str:
    """
    Orchestrate the full reconstruction pipeline.

    Parameters
    ----------
    job_id:
        UUID of the job; used to isolate work and result directories.
    upload_path:
        Absolute path to the uploaded ``.zip`` archive.
    update_progress:
        Callback ``(fraction: float, message: str) -> None`` where *fraction*
        is in ``[0.0, 1.0]``.

    Returns
    -------
    str
        Absolute path to the final ``.ply`` file in RESULTS_DIR.
    """
    upload_path_obj = Path(upload_path)
    work_dir = Path(WORK_BASE_DIR) / job_id
    result_dir = Path(RESULTS_DIR) / job_id

    work_dir.mkdir(parents=True, exist_ok=True)
    result_dir.mkdir(parents=True, exist_ok=True)

    try:
        result_ply = _run(
            job_id=job_id,
            upload_path=upload_path_obj,
            work_dir=work_dir,
            result_dir=result_dir,
            update_progress=update_progress,
            is_video=video_processor.is_video_file(upload_path_obj),
        )
    finally:
        # Clean up the working directory regardless of success / failure to
        # avoid accumulating large amounts of intermediate data on disk.
        logger.info("[job %s] Cleaning up work directory %s", job_id, work_dir)
        shutil.rmtree(work_dir, ignore_errors=True)

    return result_ply


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _run(
    job_id: str,
    upload_path: Path,
    work_dir: Path,
    result_dir: Path,
    update_progress: Callable[[float, str], None],
    is_video: bool = False,
) -> str:
    extract_dir = work_dir / "extract"
    extract_dir.mkdir(parents=True, exist_ok=True)

    if is_video:
        # ------------------------------------------------------------------
        # Step 1 – Extract frames from video via FFmpeg
        # ------------------------------------------------------------------
        logger.info("[job %s] Input is a video file; extracting frames", job_id)
        frame_count = video_processor.extract_frames(
            video_path=upload_path,
            output_dir=extract_dir,
            update_progress=lambda f, m: update_progress(0.02 + f * 0.08, m),
        )
        images_dir = extract_dir / "images"
        logger.info("[job %s] Extracted %d frames to %s", job_id, frame_count, images_dir)
        if frame_count < 3:
            raise RuntimeError(
                f"Only {frame_count} frames could be extracted from the video; "
                "need at least 3. Is the video too short?"
            )
    else:
        # ------------------------------------------------------------------
        # Step 1 – Extract ZIP
        # ------------------------------------------------------------------
        update_progress(0.02, "Extracting archive")
        logger.info("[job %s] Extracting %s → %s", job_id, upload_path, extract_dir)
        try:
            with zipfile.ZipFile(upload_path, "r") as zf:
                zf.extractall(extract_dir)
        except zipfile.BadZipFile as exc:
            raise RuntimeError(f"Uploaded file is not a valid ZIP archive: {exc}") from exc

        # ------------------------------------------------------------------
        # Step 2 – Find images directory
        # ------------------------------------------------------------------
        update_progress(0.05, "Locating image frames")
        images_dir = _find_images_dir(extract_dir)
        logger.info("[job %s] Images directory: %s", job_id, images_dir)

        frame_count = _count_images(images_dir)
        logger.info("[job %s] Frame count: %d", job_id, frame_count)
        if frame_count < 3:
            raise RuntimeError(
                f"Not enough image frames found in the archive (found {frame_count}, "
                "need at least 3)."
            )

    # ------------------------------------------------------------------
    # Step 3 – Check for existing transforms.json
    # ------------------------------------------------------------------
    update_progress(0.08, "Checking for existing camera transforms")
    transforms_json = _find_transforms_json(extract_dir)
    data_dir = work_dir / "nerfstudio_data"
    data_dir.mkdir(parents=True, exist_ok=True)

    if transforms_json is not None:
        # ----------------------------------------------------------------
        # Step 4a – ARKit / Record3D capture already has transforms
        # ----------------------------------------------------------------
        update_progress(0.10, "Using existing ARKit camera transforms")
        logger.info("[job %s] transforms.json found at %s", job_id, transforms_json)
        _prepare_nerfstudio_data_from_transforms(
            transforms_json=transforms_json,
            images_dir=images_dir,
            data_dir=data_dir,
        )
    else:
        # ----------------------------------------------------------------
        # Step 4b – Run COLMAP to recover camera poses
        # ----------------------------------------------------------------
        update_progress(0.10, "Running COLMAP feature extraction")
        logger.info("[job %s] No transforms.json found; running COLMAP", job_id)
        transforms_json = colmap_runner.run_colmap(
            images_dir=str(images_dir),
            work_dir=str(work_dir),
            update_progress=lambda f, m: update_progress(0.10 + f * 0.30, m),
        )
        # ns-process-data writes its output into work_dir; point data_dir there.
        data_dir = Path(transforms_json).parent

    # ------------------------------------------------------------------
    # Step 5 – Train splatfacto with Nerfstudio
    # ------------------------------------------------------------------
    update_progress(0.40, "Starting Nerfstudio training")
    output_dir = work_dir / "ns_output"
    output_dir.mkdir(parents=True, exist_ok=True)

    ply_path = nerfstudio_runner.train(
        data_dir=str(data_dir),
        output_dir=str(output_dir),
        update_progress=lambda f, m: update_progress(0.40 + f * 0.55, m),
    )

    # ------------------------------------------------------------------
    # Step 6 – Copy .ply to results directory
    # ------------------------------------------------------------------
    update_progress(0.96, "Copying result file")
    dest_ply = result_dir / f"reconstruction_{job_id}.ply"
    shutil.copy2(ply_path, dest_ply)
    logger.info("[job %s] Result .ply written to %s", job_id, dest_ply)

    # ------------------------------------------------------------------
    # Step 7 – Done
    # ------------------------------------------------------------------
    update_progress(1.0, "Complete")
    return str(dest_ply)


# ---------------------------------------------------------------------------
# File-system helpers
# ---------------------------------------------------------------------------


def _find_images_dir(root: Path) -> Path:
    """
    Walk the extracted archive to find the directory that contains the
    most image files.  Prefers well-known directory names if present.
    """
    # First pass: prefer well-known names at any depth.
    for candidate in _IMAGE_DIR_CANDIDATES:
        matches = sorted(root.rglob(candidate))
        for match in matches:
            if match.is_dir() and _count_images(match) > 0:
                return match

    # Second pass: pick the directory with the most images.
    best_dir: Path | None = None
    best_count = 0
    for dirpath in root.rglob("*"):
        if dirpath.is_dir():
            count = _count_images(dirpath)
            if count > best_count:
                best_count = count
                best_dir = dirpath

    if best_dir is None or best_count == 0:
        # Fall back to the extract root itself.
        return root

    return best_dir


def _count_images(directory: Path) -> int:
    """Return the number of image files (non-recursive) in *directory*."""
    image_exts = {".jpg", ".jpeg", ".png", ".tiff", ".tif", ".bmp", ".heic"}
    return sum(
        1
        for p in directory.iterdir()
        if p.is_file() and p.suffix.lower() in image_exts
    )


def _find_transforms_json(root: Path) -> Path | None:
    """Search the extracted archive for a ``transforms.json`` file."""
    matches = list(root.rglob("transforms.json"))
    if not matches:
        return None
    # Prefer the one closest to the root (shortest path).
    return min(matches, key=lambda p: len(p.parts))


def _prepare_nerfstudio_data_from_transforms(
    transforms_json: Path,
    images_dir: Path,
    data_dir: Path,
) -> None:
    """
    Prepare the Nerfstudio data directory when the archive already contains
    ``transforms.json``.  The file is validated and copied together with a
    symlink (or copy) of the images directory so that Nerfstudio can find
    everything under ``data_dir``.
    """
    # Validate basic structure of transforms.json.
    with transforms_json.open() as fh:
        transforms = json.load(fh)

    if "frames" not in transforms:
        raise RuntimeError(
            "transforms.json is missing the 'frames' key; "
            "it does not appear to be a valid Nerfstudio/NeRF capture."
        )

    # Copy transforms.json.
    shutil.copy2(transforms_json, data_dir / "transforms.json")

    # Make images available under data_dir/images/.
    dest_images = data_dir / "images"
    if not dest_images.exists():
        # Use a symlink when possible (saves disk space).
        try:
            dest_images.symlink_to(images_dir.resolve())
        except OSError:
            shutil.copytree(str(images_dir), str(dest_images))

    logger.info(
        "Prepared Nerfstudio data directory at %s (%d frames in transforms.json)",
        data_dir,
        len(transforms.get("frames", [])),
    )
