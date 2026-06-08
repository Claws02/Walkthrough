from __future__ import annotations

import uuid
from datetime import datetime, timezone
from enum import Enum
from typing import Optional

from pydantic import BaseModel, ConfigDict
from sqlalchemy import DateTime, Float, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from .database import Base


# ---------------------------------------------------------------------------
# Enum
# ---------------------------------------------------------------------------


class JobStatus(str, Enum):
    pending = "pending"
    processing = "processing"
    completed = "completed"
    failed = "failed"


# ---------------------------------------------------------------------------
# SQLAlchemy ORM model
# ---------------------------------------------------------------------------


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


class Job(Base):
    __tablename__ = "jobs"

    id: Mapped[str] = mapped_column(
        String(36),
        primary_key=True,
        default=lambda: str(uuid.uuid4()),
    )
    status: Mapped[str] = mapped_column(
        String(32),
        nullable=False,
        default=JobStatus.pending.value,
    )
    progress: Mapped[float] = mapped_column(
        Float,
        nullable=False,
        default=0.0,
    )
    message: Mapped[Optional[str]] = mapped_column(String(1024), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=_now_utc,
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=_now_utc,
        onupdate=_now_utc,
    )
    upload_path: Mapped[Optional[str]] = mapped_column(String(512), nullable=True)
    result_path: Mapped[Optional[str]] = mapped_column(String(512), nullable=True)
    frame_count: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)


# ---------------------------------------------------------------------------
# Pydantic schemas
# ---------------------------------------------------------------------------


class JobCreate(BaseModel):
    """Internal schema used when creating a job record."""

    id: str
    status: JobStatus = JobStatus.pending
    progress: float = 0.0
    message: Optional[str] = None
    upload_path: Optional[str] = None
    frame_count: Optional[int] = None


class JobResponse(BaseModel):
    """Public schema returned by the API."""

    model_config = ConfigDict(from_attributes=True)

    id: str
    status: JobStatus
    progress: float
    message: Optional[str]
    created_at: datetime
    updated_at: datetime
    result_url: Optional[str] = None
    frame_count: Optional[int]

    @classmethod
    def from_orm_job(cls, job: Job) -> "JobResponse":
        result_url: Optional[str] = None
        if job.status == JobStatus.completed and job.result_path:
            result_url = f"/api/jobs/{job.id}/result"
        return cls(
            id=job.id,
            status=job.status,  # type: ignore[arg-type]
            progress=job.progress,
            message=job.message,
            created_at=job.created_at,
            updated_at=job.updated_at,
            result_url=result_url,
            frame_count=job.frame_count,
        )


class JobListResponse(BaseModel):
    """Wrapper returned by GET /api/jobs (currently unused in favour of a
    plain list, but kept here for potential future use)."""

    model_config = ConfigDict(from_attributes=True)

    jobs: list[JobResponse]
    total: int
