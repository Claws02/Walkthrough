from __future__ import annotations

import os

from celery import Celery

# ---------------------------------------------------------------------------
# Configuration – read from environment with sensible defaults.
# ---------------------------------------------------------------------------

REDIS_URL: str = os.environ.get("REDIS_URL", "redis://redis:6379/0")

# ---------------------------------------------------------------------------
# Application instance
# ---------------------------------------------------------------------------

celery_app = Celery(
    "worker",
    broker=REDIS_URL,
    backend=REDIS_URL,
    include=["app.tasks"],
)

celery_app.conf.update(
    # Serialisation
    task_serializer="json",
    result_serializer="json",
    accept_content=["json"],
    # Result expiry
    result_expires=86400,  # 24 hours in seconds
    # Timezone
    timezone="UTC",
    enable_utc=True,
    # Worker behaviour
    worker_prefetch_multiplier=1,
    task_acks_late=True,
    task_reject_on_worker_lost=True,
    # Routing – all tasks go to the default queue
    task_default_queue="default",
    # Visibility timeout must be longer than the longest possible task.
    # GPU training can take hours; 8 h gives comfortable headroom.
    broker_transport_options={"visibility_timeout": 28800},
)
