"""Application settings loaded from environment / .env."""

from __future__ import annotations

from pathlib import Path
from typing import Literal

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

SERVER_DIR = Path(__file__).resolve().parent
BACKEND_DIR = SERVER_DIR.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=BACKEND_DIR / ".env",
        env_file_encoding="utf-8",
        env_prefix="TIGERDUCK_",
        extra="ignore",
        case_sensitive=False,
    )

    # --- App ---
    env: Literal["development", "production"] = "development"
    log_level: str = "INFO"
    api_base_path: str = "/v1"
    # Shared-secret that clients must send as X-Push-Token on write endpoints.
    # Empty string disables auth (dev/test convenience). Production must set
    # a non-empty value via TIGERDUCK_API_SHARED_SECRET.
    api_shared_secret: str = ""

    # --- Database ---
    # e.g. postgresql+asyncpg://tigerduck:password@localhost:5432/tigerduck
    database_url: str = Field(
        default="postgresql+asyncpg://tigerduck:tigerduck@localhost:5432/tigerduck"
    )
    database_echo: bool = False

    # --- APNs ---
    apns_bundle_id: str = "org.ntust.app.TigerDuck"
    apns_team_id: str = ""
    apns_key_id: str = ""
    apns_key_path: Path = SERVER_DIR / "secrets" / "apns_auth_key.p8"
    # "development" talks to api.sandbox.push.apple.com (debug builds via Xcode)
    # "production" talks to api.push.apple.com (TestFlight / App Store)
    apns_env: Literal["development", "production"] = "development"

    # --- Scheduler ---
    # how often dispatcher polls DB for due pushes
    scheduler_tick_seconds: int = 30
    # fire_at within [now, now + window_seconds] becomes eligible each tick
    scheduler_window_seconds: int = 60

    @property
    def apns_topic_live_activity(self) -> str:
        return f"{self.apns_bundle_id}.push-type.liveactivity"


def get_settings() -> Settings:
    return Settings()
