"""Let students opt in to study discovery independently of dating."""
from alembic import op
import sqlalchemy as sa
revision = '927a5cd00222'
down_revision = '713c82bf0021'
branch_labels = None
depends_on = None

def upgrade():
    op.add_column('users', sa.Column('study_visible', sa.Boolean(), nullable=True))

def downgrade():
    op.drop_column('users', 'study_visible')
