"""Store Google's verified account subject independently of email."""
from alembic import op
import sqlalchemy as sa
revision="713c82bf0021"
down_revision="16f74e91ee10"
branch_labels=None
depends_on=None
def upgrade():
    op.create_table("google_identities",sa.Column("subject",sa.String(255),primary_key=True),sa.Column("user_id",sa.Integer(),sa.ForeignKey("users.id",ondelete="CASCADE"),nullable=False,unique=True))
def downgrade():
    op.drop_table("google_identities")
