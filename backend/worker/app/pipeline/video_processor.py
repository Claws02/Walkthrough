"""
video_processor.py
~~~~~~~~~~~~~~~~~~
Extracts JPEG frames from a video file using FFmpeg.
Target: ~150 frames per job, FPS auto-calculated from video duration.
"""

from __future__ import annotations

import json
import logging
import re
import subprocess
from pathlib import Path
from typing import Callable

logger = logging.getLogger(__name__)

_VIDEO_SUFFIXES: frozenset[str] = frozenset(
    {".mp4", ".mov", ".avi", ".mkv", ".m4v", ".webm", ".MP4", ".MOV"}
)
_FRAME_RE = re.compile(r"frame=\s*(\d+)")


def is_video_file(path: Path) -> bool:
    """Return True if *path* has a recognised video file extension."""
    return path.suffix in _VIDEO_SUFFIXES


def get_video_info(video_path: Path) -> dict:
    """
    Query video metadata via ffprobe.
    Returns dict with: duration (float, s), width, height, fps, size_bytes.
    Raises RuntimeError on failure.
    """
    cmd = [
        "ffprobe", "-v", "quiet",
        "-print_format", "json",
        "-show_streams", "-show_format",
        str(video_path),
    ]
    try:
        result = subprocess.run(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace",
        )
    except FileNotFoundError as exc:
        raise RuntimeError("ffprobe not found — is FFmpeg installed?") from exc

    if result.returncode != 0:
        raise RuntimeError(
            f"ffprobe failed (exit {result.returncode}):\n{result.stderr.strip()}"
        )

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"ffprobe returned invalid JSON: {exc}") from exc

    fmt      = data.get("format", {})
    duration = float(fmt.get("duration") or 0)
    size     = int(fmt.get("size") or 0)

    width = height = 0
    fps   = 0.0

    for stream in data.get("streams", []):
        if stream.get("codec_type") != "video":
            continue
        width  = width  or int(stream.get("width",  0) or 0)
        height = height or int(stream.get("height", 0) or 0)
        if not fps:
            fps = _parse_fps(stream.get("r_frame_rate") or stream.get("avg_frame_rate") or "")
        if not duration:
            duration = float(stream.get("duration") or 0)

    if not duration:
        raise RuntimeError(f"Could not determine video duration for {video_path.name}.")

    if not size:
        try:
            size = video_path.stat().st_size
        except OSError:
            pass

    return {"duration": duration, "width": width, "height": height,
            "fps": fps, "size_bytes": size}


def compute_extraction_fps(duration: float, target_frames: int = 150) -> float:
    """Return extraction FPS clamped to [0.5, 5.0] to yield ~target_frames."""
    return max(0.5, min(5.0, target_frames / max(duration, 1.0)))


def extract_frames(
    video_path: Path,
    output_dir: Path,
    update_progress: Callable[[float, str], None],
) -> int:
    """
    Extract JPEG frames from *video_path* into output_dir/images/.
    Returns the number of frames extracted.
    Raises RuntimeError on failure.
    """
    images_dir = output_dir / "images"
    images_dir.mkdir(parents=True, exist_ok=True)

    info     = get_video_info(video_path)
    duration = info["duration"]
    fps      = compute_extraction_fps(duration)
    est      = max(1, int(duration * fps))

    update_progress(0.0, f"Extracting frames from {duration:.0f}s video at {fps:.1f} FPS…")
    logger.info("extract_frames: %s  dur=%.1fs fps=%.2f est=%d", video_path.name, duration, fps, est)

    # -progress pipe:1 emits newline-delimited "frame=N" key/value pairs on
    # stdout; ffmpeg's human-readable stats use \r endings that never stream
    # through line iteration. -loglevel error keeps stderr small enough that
    # its pipe buffer cannot fill and deadlock the process.
    cmd = [
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-nostats", "-progress", "pipe:1",
        "-i", str(video_path),
        "-vf", f"fps={fps:.3f},scale=1920:-2:flags=lanczos",
        "-q:v", "2",
        "-vsync", "vfr",  # -fps_mode requires ffmpeg >= 5.1; Ubuntu 22.04 ships 4.4
        str(images_dir / "frame_%04d.jpg"),
    ]

    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace",
        )
    except FileNotFoundError as exc:
        raise RuntimeError("ffmpeg not found — is FFmpeg installed?") from exc

    last_frame = 0
    for line in proc.stdout:  # type: ignore[union-attr]
        m = _FRAME_RE.search(line)
        if m:
            cur = int(m.group(1))
            if cur != last_frame:
                last_frame = cur
                frac = min(cur / est, 1.0)
                update_progress(0.05 + frac * 0.90, f"Extracting frames… {cur}/{est}")

    _, stderr_text = proc.communicate()

    if proc.returncode != 0:
        tail = "\n".join((stderr_text or "").splitlines()[-30:])
        raise RuntimeError(
            f"FFmpeg failed (exit {proc.returncode}).\nLast output:\n{tail}"
        )

    frames = list(images_dir.glob("frame_*.jpg"))
    if not frames:
        raise RuntimeError(
            f"FFmpeg exited cleanly but no frames found in {images_dir}."
        )

    count = len(frames)
    update_progress(1.0, f"Extracted {count} frames")
    logger.info("extract_frames: extracted %d frames", count)
    return count


def _parse_fps(raw: str) -> float:
    if not raw:
        return 0.0
    if "/" in raw:
        try:
            n, d = raw.split("/", 1)
            return float(n) / float(d) if float(d) else 0.0
        except (ValueError, ZeroDivisionError):
            return 0.0
    try:
        return float(raw)
    except ValueError:
        return 0.0
