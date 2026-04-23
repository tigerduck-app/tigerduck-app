"""add platform column to device_registrations

Revision ID: 8e98f2ebb2d2
Revises: 8ef231bb5a0c
Create Date: 2026-04-22 20:51:31.524035

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '8e98f2ebb2d2'
down_revision: Union[str, Sequence[str], None] = '8ef231bb5a0c'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Add a `platform` column so the dispatcher can branch APNs vs FCM.

    server_default='apple' backfills existing rows (all current clients are
    iOS) and keeps the column optional on the wire — an iOS client that
    hasn't been rebuilt to send `platform` will still register successfully.
    """
    op.add_column(
        "device_registrations",
        sa.Column(
            "platform",
            sa.String(length=16),
            nullable=False,
            server_default="apple",
        ),
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("device_registrations", "platform")
