from __future__ import annotations

import logging
import os
import shutil
import uuid
from pathlib import Path
from typing import List, Optional

import aiofiles
from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, status
from fastapi.responses import FileResponse
from sqlalchemy import delete, desc, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import settings
from ..database import get_db
from ..models import Job, JobResponse, JobStatus

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/jobs", tags=["jobs"])


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


async def _get_job_or_404(job_id: str, db: AsyncSession) -> Job:
    result = await db.execute(select(Job).where(Job.id == job_id))
    job = result.scalar_one_or_none()
    if job is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Job '{job_id}' not found.",
        )
    return job


def _publish_task(job_id: str, upload_path: str) -> None:
    """Import Celery task lazily to avoid hard dependency at import time."""
    try:
        from app.celery_app import celery_app  # worker package  # noqa: F401

        celery_app.send_task(
            "app.tasks.process_scan",
            args=[job_id, upload_path],
        )
    except Exception:
        # If the Celery import fails (e.g. in the API container where celery_app
        # is not installed), fall back to sending the task directly via the broker.
        from celery import Celery  # type: ignore

        app = Celery(broker=settings.REDIS_URL, backend=settings.REDIS_URL)
        app.send_task(
            "app.tasks.process_scan",
            args=[job_id, upload_path],
        )


# ---------------------------------------------------------------------------
# POST /api/jobs
# ---------------------------------------------------------------------------


@router.post(
    "",
    response_model=JobResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Create a job record (optionally with immediate file upload)",
    description=(
        "If a `file` field is provided in the multipart body the scan is uploaded "
        "immediately and processing starts. If no file is provided a bare job record "
        "is created so the client can upload the file later via "
        "POST /api/jobs/{job_id}/upload."
    ),
)
async def create_job(
    file: Optional[UploadFile] = File(None, description="ZIP archive (optional)"),
    db: AsyncSession = Depends(get_db),
) -> JobResponse:
    job_id = str(uuid.uuid4())

    # ------------------------------------------------------------------
    # Persist job record first (so the client gets an ID immediately)
    # ------------------------------------------------------------------
    job = Job(
        id=job_id,
        status=JobStatus.pending.value,
        progress=0.0,
    )
    db.add(job)
    await db.flush()

    if file is not None and file.filename:
        # Inline upload path — same logic as POST /api/jobs/{id}/upload
        upload_job_dir = Path(settings.UPLOAD_DIR) / job_id
        upload_job_dir.mkdir(parents=True, exist_ok=True)
        original_filename = Path(file.filename or "scan.zip").name
        dest_path = upload_job_dir / original_filename

        max_bytes = settings.max_upload_size_bytes
        bytes_written = 0
        try:
            async with aiofiles.open(dest_path, "wb") as out_file:
                while True:
                    chunk = await file.read(1024 * 1024)
                    if not chunk:
                        break
                    bytes_written += len(chunk)
                    if bytes_written > max_bytes:
                        raise HTTPException(
                            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                            detail=f"Upload exceeds maximum of {settings.MAX_UPLOAD_SIZE_MB} MB.",
                        )
                    await out_file.write(chunk)
        except HTTPException:
            shutil.rmtree(upload_job_dir, ignore_errors=True)
            raise
        except Exception as exc:
            shutil.rmtree(upload_job_dir, ignore_errors=True)
            logger.exception("Failed to save uploaded file for job %s", job_id)
            raise HTTPException(status_code=500, detail="Failed to save uploaded file.") from exc

        job.upload_path = str(dest_path)
        await db.flush()
        try:
            _publish_task(job_id, str(dest_path))
        except Exception as exc:
            logger.exception("Failed to enqueue task for job %s", job_id)
            job.status = JobStatus.failed.value
            job.message = "Failed to enqueue processing task."
            await db.flush()

        logger.info("Created job %s with inline upload (%d bytes)", job_id, bytes_written)
    else:
        logger.info("Created bare job %s (awaiting upload)", job_id)

    return JobResponse.from_orm_job(job)


# ---------------------------------------------------------------------------
# POST /api/jobs/{job_id}/upload  — separate upload step
# ---------------------------------------------------------------------------


@router.post(
    "/{job_id}/upload",
    response_model=JobResponse,
    summary="Upload scan data for an existing job and start processing",
)
async def upload_scan(
    job_id: str,
    file: UploadFile = File(..., description="ZIP archive of iPhone ARKit scan data"),
    db: AsyncSession = Depends(get_db),
) -> JobResponse:
    job = await _get_job_or_404(job_id, db)

    if job.status not in (JobStatus.pending.value,):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Job {job_id} cannot accept an upload in status '{job.status}'.",
        )

    if not (file.filename or "").lower().endswith(".zip") and file.content_type not in (
        "application/zip", "application/x-zip-compressed", "application/octet-stream",
    ):
        raise HTTPException(status_code=422, detail="Uploaded file must be a ZIP archive.")

    upload_job_dir = Path(settings.UPLOAD_DIR) / job_id
    upload_job_dir.mkdir(parents=True, exist_ok=True)
    dest_path = upload_job_dir / Path(file.filename or "scan.zip").name

    max_bytes = settings.max_upload_size_bytes
    bytes_written = 0
    try:
        async with aiofiles.open(dest_path, "wb") as out_file:
            while True:
                chunk = await file.read(1024 * 1024)
                if not chunk:
                    break
                bytes_written += len(chunk)
                if bytes_written > max_bytes:
                    raise HTTPException(
                        status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                        detail=f"Upload exceeds maximum of {settings.MAX_UPLOAD_SIZE_MB} MB.",
                    )
                await out_file.write(chunk)
    except HTTPException:
        raise
    except Exception as exc:
        logger.exception("Failed to save file for job %s", job_id)
        raise HTTPException(status_code=500, detail="Failed to save uploaded file.") from exc

    job.upload_path = str(dest_path)
    await db.flush()

    try:
        _publish_task(job_id, str(dest_path))
    except Exception as exc:
        logger.exception("Failed to enqueue task for job %s", job_id)
        job.status = JobStatus.failed.value
        job.message = "Failed to enqueue processing task."
        await db.flush()

    logger.info("Upload complete for job %s (%d bytes)", job_id, bytes_written)
    return JobResponse.from_orm_job(job)


# ---------------------------------------------------------------------------
# GET /api/jobs
# ---------------------------------------------------------------------------


@router.get(
    "",
    response_model=List[JobResponse],
    summary="List all reconstruction jobs",
)
async def list_jobs(db: AsyncSession = Depends(get_db)) -> List[JobResponse]:
    result = await db.execute(select(Job).order_by(desc(Job.created_at)))
    jobs = result.scalars().all()
    return [JobResponse.from_orm_job(j) for j in jobs]


# ---------------------------------------------------------------------------
# GET /api/jobs/{job_id}
# ---------------------------------------------------------------------------


@router.get(
    "/{job_id}",
    response_model=JobResponse,
    summary="Get a single reconstruction job",
)
async def get_job(
    job_id: str,
    db: AsyncSession = Depends(get_db),
) -> JobResponse:
    job = await _get_job_or_404(job_id, db)
    return JobResponse.from_orm_job(job)


# ---------------------------------------------------------------------------
# DELETE /api/jobs/{job_id}
# ---------------------------------------------------------------------------


@router.delete(
    "/{job_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Delete a job and all associated files",
)
async def delete_job(
    job_id: str,
    db: AsyncSession = Depends(get_db),
) -> None:
    job = await _get_job_or_404(job_id, db)

    # Remove upload directory
    upload_job_dir = Path(settings.UPLOAD_DIR) / job_id
    if upload_job_dir.exists():
        shutil.rmtree(upload_job_dir, ignore_errors=True)

    # Remove result directory / file
    result_job_dir = Path(settings.RESULTS_DIR) / job_id
    if result_job_dir.exists():
        shutil.rmtree(result_job_dir, ignore_errors=True)
    elif job.result_path:
        result_file = Path(job.result_path)
        if result_file.exists():
            result_file.unlink(missing_ok=True)

    await db.execute(delete(Job).where(Job.id == job_id))
    logger.info("Deleted job %s", job_id)


# ---------------------------------------------------------------------------
# GET /api/jobs/{job_id}/result
# ---------------------------------------------------------------------------


@router.get(
    "/{job_id}/result",
    summary="Download the reconstructed .ply / .spz file",
)
async def get_job_result(
    job_id: str,
    db: AsyncSession = Depends(get_db),
) -> FileResponse:
    job = await _get_job_or_404(job_id, db)

    if job.status != JobStatus.completed.value:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Job is not completed yet (current status: {job.status}).",
        )

    if not job.result_path:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Result file path is not set for this job.",
        )

    result_path = Path(job.result_path)
    if not result_path.exists():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Result file no longer exists on disk.",
        )

    suffix = result_path.suffix.lower()
    media_type_map = {
        ".ply": "application/octet-stream",
        ".spz": "application/octet-stream",
    }
    media_type = media_type_map.get(suffix, "application/octet-stream")
    download_name = f"reconstruction_{job_id}{suffix}"

    return FileResponse(
        path=str(result_path),
        media_type=media_type,
        filename=download_name,
    )
