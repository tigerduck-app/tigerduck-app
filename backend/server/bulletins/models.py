"""ORM models for the bulletin pipeline.

Tables
------
* `bulletins` — one row per distinct bulletin observed. `external_id` is the
  `Sn=` in the source URL; `content_hash` hashes normalized title+body so we
  can detect re-posts that reuse the same content under a different ID.
* `bulletin_subscriptions` — per-device rules. Each row is one rule; a
  bulletin notifies the device if ANY enabled rule matches (see
  `matcher.rule_hits`). Empty `orgs`/`tags` array means wildcard on that
  dimension.
* `bulletin_dispatches` — (bulletin, device) fan-out state. The unique
  constraint guarantees a bulletin is sent to a given device at most once.
"""

from __future__ import annotations

from datetime import datetime
from enum import StrEnum

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.dialects.postgresql import ARRAY, JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from server.db import Base


class BulletinProcessingState(StrEnum):
    pending = "pending"
    processed = "processed"
    failed = "failed"
    skipped = "skipped"  # deduped reposts — stored but never notified


class BulletinDispatchStatus(StrEnum):
    pending = "pending"
    sent = "sent"
    failed = "failed"
    cancelled = "cancelled"


class Bulletin(Base):
    __tablename__ = "bulletins"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    source: Mapped[str] = mapped_column(String(32), default="ntust_general")
    external_id: Mapped[str] = mapped_column(String(64))
    source_url: Mapped[str] = mapped_column(Text)
    raw_publisher: Mapped[str | None] = mapped_column(String(128), nullable=True)

    # LLM outputs — populated when processing_state flips to 'processed'.
    canonical_org: Mapped[str | None] = mapped_column(String(32), nullable=True)
    content_tags: Mapped[list[str]] = mapped_column(
        ARRAY(String(32)), server_default="{}", default=list
    )
    summary: Mapped[str | None] = mapped_column(Text, nullable=True)
    body_clean: Mapped[str | None] = mapped_column(Text, nullable=True)
    importance: Mapped[str | None] = mapped_column(String(16), nullable=True)

    title: Mapped[str] = mapped_column(Text)
    body_md: Mapped[str | None] = mapped_column(Text, nullable=True)

    posted_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    first_seen_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    last_seen_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    content_hash: Mapped[str | None] = mapped_column(String(64), nullable=True)

    processing_state: Mapped[str] = mapped_column(
        String(16), default=BulletinProcessingState.pending.value
    )
    processing_error: Mapped[str | None] = mapped_column(Text, nullable=True)
    processing_attempts: Mapped[int] = mapped_column(Integer, default=0)

    is_deleted: Mapped[bool] = mapped_column(Boolean, default=False)
    notified_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    dispatches: Mapped[list["BulletinDispatch"]] = relationship(
        back_populates="bulletin", cascade="all, delete-orphan"
    )

    __table_args__ = (
        UniqueConstraint("source", "external_id", name="uq_bulletins_source_extid"),
        Index(
            "ix_bulletins_content_hash",
            "source",
            "content_hash",
            unique=True,
            postgresql_where=(content_hash.isnot(None)),
        ),
        Index(
            "ix_bulletins_pending",
            "processing_state",
            postgresql_where=(processing_state == "pending"),
        ),
        Index(
            "ix_bulletins_notify_queue",
            "processing_state",
            "notified_at",
            postgresql_where=(notified_at.is_(None)),
        ),
    )


class BulletinSubscription(Base):
    __tablename__ = "bulletin_subscriptions"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    device_id: Mapped[str] = mapped_column(
        String(128),
        ForeignKey("device_registrations.device_id", ondelete="CASCADE"),
        index=True,
    )
    name: Mapped[str | None] = mapped_column(String(64), nullable=True)
    orgs: Mapped[list[str]] = mapped_column(
        ARRAY(String(32)), server_default="{}", default=list
    )
    tags: Mapped[list[str]] = mapped_column(
        ARRAY(String(32)), server_default="{}", default=list
    )
    mode: Mapped[str] = mapped_column(String(4), default="AND")
    enabled: Mapped[bool] = mapped_column(Boolean, default=True)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    __table_args__ = (
        CheckConstraint("mode IN ('AND','OR')", name="ck_subs_mode"),
        Index(
            "ix_subs_enabled_device",
            "device_id",
            postgresql_where=(enabled.is_(True)),
        ),
    )


class BulletinDispatch(Base):
    __tablename__ = "bulletin_dispatches"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    bulletin_id: Mapped[int] = mapped_column(
        BigInteger,
        ForeignKey("bulletins.id", ondelete="CASCADE"),
        index=True,
    )
    device_id: Mapped[str] = mapped_column(
        String(128),
        ForeignKey("device_registrations.device_id", ondelete="CASCADE"),
        index=True,
    )
    status: Mapped[str] = mapped_column(
        String(16), default=BulletinDispatchStatus.pending.value
    )
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    last_error: Mapped[str | None] = mapped_column(Text, nullable=True)
    sent_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    payload_json: Mapped[dict | None] = mapped_column(JSONB, nullable=True)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    bulletin: Mapped[Bulletin] = relationship(back_populates="dispatches")

    __table_args__ = (
        UniqueConstraint(
            "bulletin_id", "device_id", name="uq_dispatch_bulletin_device"
        ),
        Index(
            "ix_dispatches_due",
            "status",
            postgresql_where=(status == "pending"),
        ),
    )
