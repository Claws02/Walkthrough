from __future__ import annotations

import logging
import os
from datetime import datetime, timezone
from typing import Optional

from sqlalchemy import create_engine, update
from sqlalchemy.orm import Session, sessionmaker

from .celery_app import celery_app
from .pipeline import runner

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Synchronous DB helpers (worker has no async event loop)
# ---------------------------------------------------------------------------

DATABASE_URL: str = os.environ.get(
    "DATABASE_URL",
    "sqlite:////data/db.sqlite3",
)

# aiosqlite is not needed in the worker – use the plain sqlite3 driver.
# Strip the "+aiosqlite" dialect modifier if present so SQLAlchemy can
# create a standard synchronous engine.
_SYNC_DATABASE_URL = DATABASE_URL.replace("+aiosqlite", "")

_engine = create_engine(
    _SYNC_DATABASE_URL,
    # The API writes to the same SQLite file from another container; a
    # generous busy timeout avoids "database is locked" errors.
    connect_args={"check_same_thread": False, "timeout": 30},
    pool_pre_ping=True,
)
_SessionLocal = sessionmaker(bind=_engine, autoflush=False, autocommit=False)


def _get_session() -> Session:
    return _SessionLocal()


def _update_job(
    job_id: str,
    *,
    status: Optional[str] = None,
    progress: Optional[float] = None,
    message: Optional[str] = None,
    result_path: Optional[str] = None,
    frame_count: Optional[int] = None,
) -> None:
    """Persist job state changes to the SQLite database."""
    values: dict = {"updated_at": datetime.now(timezone.utc)}
    if status is not None:
        values["status"] = status
    if progress is not None:
        values["progress"] = progress
    if message is not None:
        values["message"] = message
    if result_path is not None:
        values["result_path"] = result_path
    if frame_count is not None:
        values["frame_count"] = frame_count

    with _get_session() as session:
        session.execute(
            update(_JobTable).where(_JobTable.id == job_id).values(**values)
        )
        session.commit()


# Lazy import of the ORM model – avoids circular imports and keeps the
# worker package independent from the API package at module load time.
class _JobTable:
    """Minimal stub; replaced at first use by the real ORM class."""

    pass


def _resolve_job_table() -> type:
    """Import the real Job ORM model from the shared models module."""
    try:
        # When running inside the worker container the api package is not
        # installed, so we define a minimal inline mapping instead.
        from sqlalchemy import (
            Column,
            DateTime,
            Float,
            Integer,
            String,
        )
        from sqlalchemy.orm import DeclarativeBase

        class _Base(DeclarativeBase):
            pass

        class _Job(_Base):
            __tablename__ = "jobs"
            __table_args__ = {"extend_existing": True}

            id = Column(String(36), primary_key=True)
            status = Column(String(32))
            progress = Column(Float)
            message = Column(String(1024))
            created_at = Column(DateTime(timezone=True))
            updated_at = Column(DateTime(timezone=True))
            upload_path = Column(String(512))
            result_path = Column(String(512))
            frame_count = Column(Integer)

        return _Job
    except Exception:
        raise


# Resolve and cache the real table class once at module level.
_JobTable = _resolve_job_table()  # type: ignore[misc,assignment]


# ---------------------------------------------------------------------------
# Celery task
# ---------------------------------------------------------------------------


@celery_app.task(bind=True, name="app.tasks.process_scan", max_retries=0)
def process_scan(self, job_id: str, upload_path: str) -> dict:
    """
    Main Celery task.  Orchestrates the full COLMAP → Nerfstudio pipeline
    for a single iPhone ARKit scan.

    Parameters
    ----------
    job_id:
        UUID of the job record in the database.
    upload_path:
        Absolute path to the uploaded ZIP archive on the shared volume.

    Returns
    -------
    dict
        ``{"job_id": job_id, "result_path": "<path to .ply>"}`` on success.
    """
    logger.info("process_scan started — job_id=%s upload_path=%s", job_id, upload_path)

    # ------------------------------------------------------------------
    # Mark job as processing
    # ------------------------------------------------------------------
    _update_job(job_id, status="processing", progress=0.0, message="Pipeline started")

    def _update_progress(fraction: float, message: str) -> None:
        """Callback forwarded into the pipeline runner."""
        pct = round(min(max(fraction, 0.0), 1.0), 4)
        logger.info("[job %s] progress=%.1f%%  %s", job_id, pct * 100, message)
        _update_job(job_id, progress=pct, message=message)

    # ------------------------------------------------------------------
    # Run pipeline
    # ------------------------------------------------------------------
    try:
        result_ply_path = runner.run_pipeline(
            job_id=job_id,
            upload_path=upload_path,
            update_progress=_update_progress,
        )
    except Exception as exc:  # noqa: BLE001
        logger.exception("Pipeline failed for job %s", job_id)
        _update_job(
            job_id,
            status="failed",
            progress=0.0,
            message=f"Pipeline error: {exc}",
        )
        raise

    # ------------------------------------------------------------------
    # Mark job as completed
    # ------------------------------------------------------------------
    _update_job(
        job_id,
        status="completed",
        progress=1.0,
        message="Reconstruction complete",
        result_path=result_ply_path,
    )
    logger.info("process_scan finished — job_id=%s result=%s", job_id, result_ply_path)
    return {"job_id": job_id, "result_path": result_ply_path}
