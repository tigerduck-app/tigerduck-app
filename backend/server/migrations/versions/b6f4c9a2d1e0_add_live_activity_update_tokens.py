"""add live activity update tokens

Revision ID: b6f4c9a2d1e0
Revises: 9a4c7e1f2d8b
Create Date: 2026-04-24 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = 'b6f4c9a2d1e0'
down_revision: Union[str, Sequence[str], None] = '9a4c7e1f2d8b'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        'live_activity_update_tokens',
        sa.Column('activity_id', sa.String(length=256), nullable=False),
        sa.Column('device_id', sa.String(length=128), nullable=False),
        sa.Column('source_id', sa.String(length=128), nullable=False),
        sa.Column('scenario', sa.String(length=32), nullable=False),
        sa.Column('update_token_hex', sa.String(length=512), nullable=False),
        sa.Column('countdown_target', sa.DateTime(timezone=True), nullable=True),
        sa.Column('snapshot_json', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column('status', sa.String(length=16), nullable=False),
        sa.Column('attempts', sa.BigInteger(), nullable=False),
        sa.Column('last_error', sa.Text(), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.Column('ended_at', sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(['device_id'], ['device_registrations.device_id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('activity_id'),
    )
    op.create_index(op.f('ix_live_activity_update_tokens_countdown_target'), 'live_activity_update_tokens', ['countdown_target'], unique=False)
    op.create_index(op.f('ix_live_activity_update_tokens_device_id'), 'live_activity_update_tokens', ['device_id'], unique=False)
    op.create_index('ix_live_activity_tokens_due', 'live_activity_update_tokens', ['status', 'countdown_target'], unique=False)


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index('ix_live_activity_tokens_due', table_name='live_activity_update_tokens')
    op.drop_index(op.f('ix_live_activity_update_tokens_device_id'), table_name='live_activity_update_tokens')
    op.drop_index(op.f('ix_live_activity_update_tokens_countdown_target'), table_name='live_activity_update_tokens')
    op.drop_table('live_activity_update_tokens')
