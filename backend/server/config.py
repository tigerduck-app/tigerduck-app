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

    # --- Live Activity token retention ---
    # Prune update-token rows that reached a terminal state (ended / failed /
    # cancelled) and have not been touched since `live_activity_token_retention_days`.
    # Active rows are never pruned; a device that stops syncing keeps its
    # pending rows until the device itself is unregistered and the cascade
    # delete fires.
    live_activity_token_retention_days: int = 30
    live_activity_token_retention_interval_hours: int = 24

    # --- Bulletins ---
    bulletin_list_url: str = (
        "https://bulletin.ntust.edu.tw/p/403-1045-1391-1.php"
    )
    bulletin_scrape_interval_seconds: int = 600   # 10 min
    bulletin_process_interval_seconds: int = 60
    bulletin_dispatch_interval_seconds: int = 60
    # Rows whose last_seen_at is older than N scrape cycles get is_deleted=true.
    bulletin_stale_cycles: int = 3
    # Max processing retries before giving up on a bulletin.
    bulletin_max_process_attempts: int = 3
    # Delete is_deleted=true rows this old to keep the table bounded. Rows
    # still visible on the bulletin board keep refreshing last_seen_at and
    # stay forever; only the ones that fell off the list and aged out go.
    bulletin_retention_days: int = 365
    # Retention job runs at this cadence. Once a day is plenty.
    bulletin_retention_interval_hours: int = 24
    # Optional PEM file bundling NTUST's root + intermediates. When set and
    # readable, the bulletin HTTP client uses it as the trust anchor so
    # OpenSSL can complete the chain (the NTUST servers themselves ship
    # incomplete chains). When unset, the client falls back to the MVP
    # behavior of `verify=False` — still functional, but skips hostname /
    # chain validation. Obtain the bundle via `openssl s_client -showcerts`
    # against each NTUST subdomain the pipeline reaches.
    bulletin_ca_bundle: Path | None = None

    # --- LLM (OpenAI-compatible endpoint: llama.cpp, Gemini, vLLM, ...) ---
    llm_base_url: str = "http://localhost:8080/v1"
    llm_api_key: str = "sk-local"
    llm_model: str = "gemma-4-e4b-it"
    # 120s is generous because multi-slot llama.cpp fans one backend
    # GPU across concurrent requests, so effective per-request latency
    # scales with the backfill `--concurrency`. 30s was too tight for
    # Gemma-4 E4B on Apple Silicon at 3× concurrency.
    llm_timeout_seconds: float = 120.0
    llm_max_retries: int = 2
    llm_temperature: float = 0.2

    @property
    def apns_topic_live_activity(self) -> str:
        return f"{self.apns_bundle_id}.push-type.liveactivity"


def get_settings() -> Settings:
    return Settings()
