from __future__ import annotations

import logging
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, AsyncGenerator, Dict

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from .config import settings
from .database import init_db
from .routers.jobs import router as jobs_router

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s  %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Lifespan (startup / shutdown)
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    # ---- startup ----
    logger.info("Starting up Walkthrough API v%s", settings.VERSION)

    # Ensure data directories exist
    for directory in (settings.UPLOAD_DIR, settings.RESULTS_DIR):
        Path(directory).mkdir(parents=True, exist_ok=True)
        logger.info("Ensured directory exists: %s", directory)

    # Initialise database schema
    await init_db()

    logger.info("Startup complete.")
    yield

    # ---- shutdown ----
    logger.info("Shutting down Walkthrough API.")


# ---------------------------------------------------------------------------
# Application factory
# ---------------------------------------------------------------------------


def create_app() -> FastAPI:
    app = FastAPI(
        title="Walkthrough Reconstruction API",
        version=settings.VERSION,
        description=(
            "Processes iPhone ARKit scan archives into 3-D Gaussian Splat files "
            "via COLMAP + Nerfstudio."
        ),
        lifespan=lifespan,
        docs_url="/docs",
        redoc_url="/redoc",
        openapi_url="/openapi.json",
    )

    # ------------------------------------------------------------------
    # CORS
    # ------------------------------------------------------------------
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.CORS_ORIGINS,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    # ------------------------------------------------------------------
    # Routes
    # ------------------------------------------------------------------
    app.include_router(jobs_router)

    # ------------------------------------------------------------------
    # Static files – serve reconstructed results
    # ------------------------------------------------------------------
    results_dir = Path(settings.RESULTS_DIR)
    results_dir.mkdir(parents=True, exist_ok=True)
    app.mount(
        "/results",
        StaticFiles(directory=str(results_dir)),
        name="results",
    )

    # ------------------------------------------------------------------
    # Health endpoint
    # ------------------------------------------------------------------
    @app.get("/health", tags=["meta"], summary="Health check")
    async def health() -> Dict[str, Any]:
        return {"status": "ok", "version": settings.VERSION}

    return app


app = create_app()
