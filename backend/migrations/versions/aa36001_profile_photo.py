"""Private student profile portraits."""
from alembic import op
import sqlalchemy as sa
revision = "aa36001"
down_revision = "927a5cd00222"
branch_labels = None
depends_on = None

def upgrade():
    op.create_table("profile_photos",
        sa.Column("user_id",sa.Integer,sa.ForeignKey("users.id",ondelete="CASCADE"),primary_key=True),
        sa.Column("version",sa.String(32),nullable=False),
        sa.Column("image",sa.LargeBinary,nullable=False))

def downgrade():
    op.drop_table("profile_photos")
