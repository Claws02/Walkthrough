from __future__ import annotations

from typing import List

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    DATABASE_URL: str = "sqlite+aiosqlite:////data/db.sqlite3"
    REDIS_URL: str = "redis://redis:6379/0"
    UPLOAD_DIR: str = "/data/uploads"
    RESULTS_DIR: str = "/data/results"
    MAX_UPLOAD_SIZE_MB: int = 1024
    CORS_ORIGINS: List[str] = ["*"]

    VERSION: str = "1.0.0"

    @property
    def max_upload_size_bytes(self) -> int:
        return self.MAX_UPLOAD_SIZE_MB * 1024 * 1024


settings = Settings()
