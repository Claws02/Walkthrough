"""
nerfstudio_runner.py
~~~~~~~~~~~~~~~~~~~~
Wraps the Nerfstudio CLI to:

1.  Train a **splatfacto** (3-D Gaussian Splatting) model.
2.  Export the trained model to a ``.ply`` file via ``ns-export``.

Both operations are run as sub-processes so that Nerfstudio's own CUDA
initialisation is isolated from the Celery worker process.  stdout is
monitored line-by-line; recognised progress tokens are forwarded to the
``update_progress`` callback so the API can report live progress to clients.

Progress accounting
-------------------
*  0 %  →  10 %  : ``ns-train`` startup / data loading
* 10 %  →  90 %  : training iterations
* 90 %  → 100 %  : ``ns-export`` / post-processing
"""

from __future__ import annotations

import logging
import re
import subprocess
import threading
from pathlib import Path
from typing import Callable, Optional

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Total training iterations that we request.  Keeping this in sync with the
# CLI flag below lets us report accurate per-iteration progress.
_MAX_ITERATIONS: int = 30_000

# Patterns used to extract the current iteration from Nerfstudio log lines.
# Nerfstudio 1.x uses a rich-formatted progress bar; the raw text typically
# contains something like "Step 1500/30000" or "Iter: 1500".
_ITER_PATTERNS: tuple[re.Pattern, ...] = (
    re.compile(r"[Ss]tep[:\s]+(\d+)\s*/\s*(\d+)"),
    re.compile(r"[Ii]ter(?:ation)?[:\s]+(\d+)"),
    re.compile(r"\b(\d+)/30000\b"),
    re.compile(r"\[(\d+)/(\d+)\]"),
)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def train(
    data_dir: str,
    output_dir: str,
    update_progress: Optional[Callable[[float, str], None]] = None,
) -> str:
    """
    Train a splatfacto model and export the result as a ``.ply`` file.

    Parameters
    ----------
    data_dir:
        Directory containing ``transforms.json`` and an ``images/``
        sub-directory (Nerfstudio data format).
    output_dir:
        Root directory where Nerfstudio will write checkpoints and the
        exported ``.ply``.
    update_progress:
        Optional ``(fraction, message)`` callback.  *fraction* is in
        ``[0.0, 1.0]`` and scoped to this function's contribution.

    Returns
    -------
    str
        Absolute path to the exported ``.ply`` file.
    """

    def _progress(f: float, msg: str) -> None:
        if update_progress is not None:
            update_progress(f, msg)
        logger.info("[nerfstudio] %.1f%%  %s", f * 100, msg)

    data_path = Path(data_dir).resolve()
    out_path = Path(output_dir).resolve()
    out_path.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------
    # Step 1 – Training
    # ------------------------------------------------------------------
    _progress(0.0, "Starting Nerfstudio splatfacto training")
    train_cmd = [
        "ns-train",
        "splatfacto",
        "--data", str(data_path),
        "--output-dir", str(out_path),
        "--max-num-iterations", str(_MAX_ITERATIONS),
        "--pipeline.datamanager.camera-optimizer.mode", "off",
        "--viewer.quit-on-train-completion", "True",
        "--logging.local-writer.max-log-size", "0",   # suppress file log
    ]

    config_path = _run_training(
        cmd=train_cmd,
        output_dir=out_path,
        max_iterations=_MAX_ITERATIONS,
        progress_callback=lambda f, m: _progress(f * 0.88, m),
    )

    # ------------------------------------------------------------------
    # Step 2 – Export Gaussian Splat
    # ------------------------------------------------------------------
    _progress(0.90, "Exporting Gaussian Splat (.ply)")
    export_dir = out_path / "export"
    export_dir.mkdir(parents=True, exist_ok=True)

    export_cmd = [
        "ns-export",
        "gaussian-splat",
        "--load-config", str(config_path),
        "--output-dir", str(export_dir),
    ]
    _run_subprocess(export_cmd, step="ns-export")

    # Locate the exported .ply file.
    ply_path = _find_ply(export_dir)
    logger.info("[nerfstudio] Exported .ply at %s", ply_path)
    _progress(1.0, "Export complete")
    return str(ply_path)


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _run_training(
    cmd: list[str],
    output_dir: Path,
    max_iterations: int,
    progress_callback: Callable[[float, str], None],
) -> Path:
    """
    Launch ``ns-train``, stream its output, parse iteration progress, and
    return the path to the ``config.yml`` written by Nerfstudio.
    """
    logger.info("[nerfstudio:train] Running: %s", " ".join(cmd))

    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
    )

    output_lines: list[str] = []
    last_fraction: float = 0.0

    def _reader() -> None:
        nonlocal last_fraction
        assert process.stdout is not None
        for raw_line in process.stdout:
            line = raw_line.rstrip()
            output_lines.append(line)
            logger.debug("[nerfstudio:train] %s", line)

            # Try to extract iteration progress.
            fraction = _parse_iteration_fraction(line, max_iterations)
            if fraction is not None and fraction > last_fraction:
                last_fraction = fraction
                pct = int(fraction * 100)
                progress_callback(
                    fraction,
                    f"Training: iteration {int(fraction * max_iterations)}/{max_iterations} ({pct}%)",
                )

    reader_thread = threading.Thread(target=_reader, daemon=True)
    reader_thread.start()
    process.wait()
    reader_thread.join(timeout=10)

    if process.returncode != 0:
        tail = "\n".join(output_lines[-60:])
        raise RuntimeError(
            f"ns-train failed with exit code {process.returncode}.\n"
            f"Last output:\n{tail}"
        )

    # Nerfstudio writes a config.yml inside a timestamped sub-directory.
    config_path = _find_config_yml(output_dir)
    logger.info("[nerfstudio:train] Config at %s", config_path)
    return config_path


def _run_subprocess(cmd: list[str], *, step: str) -> subprocess.CompletedProcess:
    """Run *cmd* synchronously, logging output.  Raise on non-zero exit."""
    logger.info("[nerfstudio:%s] Running: %s", step, " ".join(cmd))
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
            logger.debug("[nerfstudio:%s] %s", step, line)

    if result.returncode != 0:
        tail = "\n".join((result.stdout or "").splitlines()[-40:])
        raise RuntimeError(
            f"nerfstudio step '{step}' failed with exit code {result.returncode}.\n"
            f"Last output:\n{tail}"
        )
    return result


def _parse_iteration_fraction(line: str, max_iterations: int) -> Optional[float]:
    """
    Attempt to extract the current training iteration from a log line and
    return it as a fraction of *max_iterations*.  Returns ``None`` if no
    recognisable iteration token is found.
    """
    for pattern in _ITER_PATTERNS:
        m = pattern.search(line)
        if m:
            try:
                current = int(m.group(1))
                # Some patterns capture the total as group 2.
                total = int(m.group(2)) if m.lastindex and m.lastindex >= 2 else max_iterations
                if total > 0:
                    return min(current / total, 1.0)
            except (IndexError, ValueError):
                continue
    return None


def _find_config_yml(output_dir: Path) -> Path:
    """
    Locate the ``config.yml`` written by Nerfstudio after training.
    Nerfstudio writes it to a path like:
        <output_dir>/splatfacto/<experiment_name>/<timestamp>/config.yml
    """
    candidates = sorted(output_dir.rglob("config.yml"), key=lambda p: p.stat().st_mtime)
    if not candidates:
        raise RuntimeError(
            f"Could not find config.yml under {output_dir}.  "
            "Training may have failed silently."
        )
    # The most-recently modified one belongs to this run.
    return candidates[-1]


def _find_ply(export_dir: Path) -> Path:
    """
    Find the exported ``.ply`` file inside *export_dir*.
    Nerfstudio typically names it ``splat.ply`` or ``gaussian_splat.ply``.
    """
    # Prefer files with "splat" in the name for clarity.
    candidates = sorted(export_dir.rglob("*.ply"), key=lambda p: p.stat().st_size, reverse=True)
    if not candidates:
        raise RuntimeError(
            f"No .ply file found in {export_dir} after ns-export.  "
            "Check the export logs."
        )
    # Return the largest .ply (likely the full point cloud, not a partial one).
    return candidates[0]
