"""add title_clean to bulletins

Revision ID: 9a4c7e1f2d8b
Revises: 8e98f2ebb2d2
Create Date: 2026-04-23 12:00:00.000000

Adds the LLM-normalized title column. Nullable so existing rows stay
valid until the next classification pass overwrites them.
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = '9a4c7e1f2d8b'
down_revision: Union[str, Sequence[str], None] = '8e98f2ebb2d2'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        'bulletins',
        sa.Column('title_clean', sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column('bulletins', 'title_clean')
