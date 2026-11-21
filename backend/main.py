import os
from datetime import datetime, timedelta, timezone
from typing import Optional
import jwt
from fastapi import FastAPI, Depends, HTTPException
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy import (
    create_engine,
    Column,
    Integer,
    String,
    DateTime,
    ForeignKey,
    select,
)
from sqlalchemy.orm import declarative_base, sessionmaker, Session
from pydantic import BaseModel, EmailStr, Field
from pwdlib import PasswordHash

SECRET = os.getenv("CAMPUSVIBE_JWT_SECRET")
if not SECRET or len(SECRET) < 32:
    raise RuntimeError(
        "Set CAMPUSVIBE_JWT_SECRET to a random value of at least 32 characters"
    )
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./campusvibe.db")
if DATABASE_URL.startswith(("postgres://","postgresql://")):
    DATABASE_URL="postgresql+psycopg://"+DATABASE_URL.split("://",1)[1]
if os.getenv("CAMPUS_HOSTED")=="1" and (not DATABASE_URL.startswith("postgresql+psycopg://") or os.getenv("LOCAL_MAIL")=="1" or len(os.getenv("MODERATOR_TOKEN",""))<32):
    raise RuntimeError("Hosted pilot requires private PostgreSQL, moderator secret and remote email mode")
engine = create_engine(
    DATABASE_URL,
    pool_pre_ping=True,
    connect_args=(
        {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}
    ),
)
Base = declarative_base()
SessionLocal = sessionmaker(bind=engine)
password_hash = PasswordHash.recommended()
security = HTTPBearer()
app = FastAPI(title="CampusVibe API", version="0.3.0")


class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    email = Column(String(255), unique=True, nullable=False, index=True)
    password_hash = Column(String(255), nullable=False)
    name = Column(String(120), nullable=False)
    college = Column(String(160), default="")
    branch = Column(String(120), default="")
    bio = Column(String(500), default="")
    role = Column(String(20), default="student")
    created_at = Column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )


class Register(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    email: EmailStr
    password: str = Field(min_length=10, max_length=128)


class Login(BaseModel):
    email: EmailStr
    password: str


class ProfileUpdate(BaseModel):
    name: Optional[str] = Field(default=None, min_length=2, max_length=120)
    college: Optional[str] = Field(default=None, max_length=160)
    branch: Optional[str] = Field(default=None, max_length=120)
    bio: Optional[str] = Field(default=None, max_length=500)


def db_session():
    with SessionLocal() as db:
        yield db


def view(u):
    return {
        "id": u.id,
        "name": u.name,
        "email": u.email,
        "college": u.college,
        "branch": u.branch,
        "bio": u.bio,
        "created_at": u.created_at.isoformat(),
    }


def current_user(
    creds: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(db_session),
):
    try:
        payload = jwt.decode(creds.credentials, SECRET, algorithms=["HS256"])
        uid = int(payload["sub"])
    except (jwt.PyJWTError, KeyError, ValueError):
        raise HTTPException(401, "Invalid or expired token")
    u = db.get(User, uid)
    import hmac, hashlib

    if not u or not hmac.compare_digest(
        payload.get("session", ""),
        hmac.new(SECRET.encode(), u.password_hash.encode(), hashlib.sha256).hexdigest(),
    ):
        raise HTTPException(401, "Account not found")
    return u


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/auth/register", status_code=201)
def register(data: Register, db: Session = Depends(db_session)):
    email = str(data.email).lower()
    if db.scalar(select(User).where(User.email == email)):
        raise HTTPException(409, "Email already registered")
    u = User(
        name=data.name.strip(),
        email=email,
        password_hash=password_hash.hash(data.password),
    )
    db.add(u)
    db.commit()
    db.refresh(u)
    return view(u)


@app.post("/auth/login")
def login(data: Login, db: Session = Depends(db_session)):
    u = db.scalar(select(User).where(User.email == str(data.email).lower()))
    if not u or not password_hash.verify(data.password, u.password_hash):
        raise HTTPException(401, "Invalid email or password")
    return session_for(u)

def session_for(u):
    import hmac, hashlib

    token = jwt.encode(
        {
            "sub": str(u.id),
            "session": hmac.new(
                SECRET.encode(), u.password_hash.encode(), hashlib.sha256
            ).hexdigest(),
            "exp": datetime.now(timezone.utc) + timedelta(hours=8),
        },
        SECRET,
        algorithm="HS256",
    )
    return {"access_token": token, "token_type": "bearer", "user": view(u)}


@app.get("/profile/me")
def profile_me(u: User = Depends(current_user), db: Session = Depends(db_session)):
    v = db.get(Verification, u.id)
    return {
        **view(u),
        "email_verified": bool(
            db.get(EmailChallenge, u.id) and db.get(EmailChallenge, u.id).verified
        ),
        "verification": verification_view(v),
        "interests": list(
            db.scalars(select(Interest.label).where(Interest.user_id == u.id))
        ),
    }


@app.patch("/profile/me")
def update_profile(
    data: ProfileUpdate,
    u: User = Depends(current_user),
    db: Session = Depends(db_session),
):
    check = db.get(Verification, u.id)
    if (
        check
        and data.college is not None
        and data.college.strip().casefold() != u.college.strip().casefold()
    ):
        check.college_ok = False
        check.dating = False
    for k, v in data.model_dump(exclude_unset=True).items():
        setattr(u, k, v)
    db.add(u)
    db.commit()
    db.refresh(u)
    return view(u)


@app.get("/admin/students")
def admin_students(u: User = Depends(current_user), db: Session = Depends(db_session)):
    if u.role != "admin":
        raise HTTPException(403, "Admin role required")
    return [
        view(x)
        for x in db.scalars(select(User).order_by(User.id.desc()).limit(100)).all()
    ]


# Phase-2 functional modules: real database records, no fabricated student accounts.
from sqlalchemy import Boolean, Text, UniqueConstraint, or_
from fastapi import WebSocket, WebSocketDisconnect


class Interest(Base):
    __tablename__ = "interests"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    label = Column(String(80), nullable=False)
    __table_args__ = (UniqueConstraint("user_id", "label"),)


class Connection(Base):
    __tablename__ = "connections"
    id = Column(Integer, primary_key=True)
    sender_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    receiver_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    kind = Column(String(20), nullable=False)  # study, friend, dating
    status = Column(String(20), default="pending")
    created_at = Column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )
    __table_args__ = (UniqueConstraint("sender_id", "receiver_id", "kind"),)


class Book(Base):
    __tablename__ = "books"
    id = Column(Integer, primary_key=True)
    owner_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    title = Column(String(180), nullable=False)
    author = Column(String(120), default="")
    condition = Column(String(30), default="good")
    price = Column(Integer, default=0)
    available = Column(Boolean, default=True)
    created_at = Column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )


class Message(Base):
    __tablename__ = "messages"
    id = Column(Integer, primary_key=True)
    sender_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    receiver_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    body = Column(Text, nullable=False)
    created_at = Column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )


class Community(Base):
    __tablename__ = "communities"
    id = Column(Integer, primary_key=True)
    owner_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    name = Column(String(120), nullable=False)
    description = Column(String(500), default="")


class Membership(Base):
    __tablename__ = "memberships"
    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    community_id = Column(Integer, ForeignKey("communities.id"), nullable=False)
    __table_args__ = (UniqueConstraint("user_id", "community_id"),)


class Report(Base):
    __tablename__ = "reports"
    id = Column(Integer, primary_key=True)
    reporter_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    target_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    reason = Column(String(500), nullable=False)
    status = Column(String(20), default="open")


class Block(Base):
    __tablename__ = "blocks"
    id = Column(Integer, primary_key=True)
    blocker_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    blocked_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    __table_args__ = (UniqueConstraint("blocker_id", "blocked_id"),)


from membership import define_membership, Settings, compatible, adult

Verification = define_membership(Base)


class InterestInput(BaseModel):
    labels: list[str] = Field(max_length=30)


class ConnectionInput(BaseModel):
    receiver_id: int
    kind: str


class BookInput(BaseModel):
    title: str = Field(min_length=1, max_length=180)
    author: str = Field(default="", max_length=120)
    condition: str = "good"
    price: int = Field(default=0, ge=0)


class MessageInput(BaseModel):
    receiver_id: int
    body: str = Field(min_length=1, max_length=5000)


class CommunityInput(BaseModel):
    name: str = Field(min_length=3, max_length=120)
    description: str = Field(default="", max_length=500)


class ReportInput(BaseModel):
    target_id: int
    reason: str = Field(min_length=5, max_length=500)


def blocked(db, a, b):
    return (
        db.scalar(
            select(Block).where(
                or_(
                    (Block.blocker_id == a) & (Block.blocked_id == b),
                    (Block.blocker_id == b) & (Block.blocked_id == a),
                )
            )
        )
        is not None
    )


def accepted(db, a, b):
    for conn in db.scalars(
        select(Connection).where(
            Connection.status == "accepted",
            or_(
                (Connection.sender_id == a) & (Connection.receiver_id == b),
                (Connection.sender_id == b) & (Connection.receiver_id == a),
            ),
        )
    ):
        try:
            validate_pair(db, db.get(User, a), b, conn.kind)
            return True
        except HTTPException:
            pass
    return False


@app.put("/interests")
def set_interests(
    data: InterestInput,
    u: User = Depends(current_user),
    db: Session = Depends(db_session),
):
    from sqlalchemy import delete

    db.execute(delete(Interest).where(Interest.user_id == u.id))
    labels = sorted({x.strip().lower() for x in data.labels if x.strip()})
    for label in labels:
        db.add(Interest(user_id=u.id, label=label[:80]))
    db.commit()
    return {"interests": labels}


@app.get("/discover")
def discover(
    kind: str = "study",
    u: User = Depends(current_user),
    db: Session = Depends(db_session),
):
    if kind not in ("study", "friend", "dating"):
        raise HTTPException(400, "Invalid discovery mode")
    mine_v = require_member(db, u)
    if kind == "dating" and not (
        mine_v.adult_checked and mine_v.dating and adult(mine_v.dob)
    ):
        raise HTTPException(403, "Verify adult eligibility and opt in under Profile")
    mine = {
        x.label for x in db.scalars(select(Interest).where(Interest.user_id == u.id))
    }
    candidates = db.scalars(
        select(User)
        .join(Verification, Verification.user_id == User.id)
        .where(
            User.id != u.id, Verification.college_ok == True, User.college == u.college
        )
        .limit(100)
    ).all()
    out = []
    for person in candidates:
        if blocked(db, u.id, person.id) or (
            kind == "dating" and not compatible(mine_v, db.get(Verification, person.id))
        ):
            continue
        shared = sorted(
            mine
            & {
                x.label
                for x in db.scalars(
                    select(Interest).where(Interest.user_id == person.id)
                )
            }
        )
        out.append(
            {
                "id": person.id,
                "name": person.name,
                "college": person.college,
                "branch": person.branch,
                "bio": person.bio,
                "shared_interests": shared,
                "score": len(shared),
            }
        )
    return sorted(out, key=lambda x: x["score"], reverse=True)[:30]


@app.post("/connections", status_code=201)
def request_connection(
    data: ConnectionInput,
    u: User = Depends(current_user),
    db: Session = Depends(db_session),
):
    validate_pair(db, u, data.receiver_id, data.kind)
    if not allowed("discover:" + str(u.id), 20, 86400):
        raise HTTPException(429, "Daily connection limit reached")
    if data.receiver_id == u.id or not db.get(User, data.receiver_id):
        raise HTTPException(400, "Invalid recipient")
    if blocked(db, u.id, data.receiver_id):
        raise HTTPException(403, "Connection unavailable")
    existing = db.scalar(
        select(Connection).where(
            Connection.sender_id == u.id,
            Connection.receiver_id == data.receiver_id,
            Connection.kind == data.kind,
        )
    )
    if existing:
        raise HTTPException(409, "Request already exists")
    c = Connection(sender_id=u.id, receiver_id=data.receiver_id, kind=data.kind)
    db.add(c)
    db.commit()
    db.refresh(c)
    return {"id": c.id, "status": c.status}


@app.get("/connections")
def connections(u: User = Depends(current_user), db: Session = Depends(db_session)):
    items = db.scalars(
        select(Connection).where(
            or_(Connection.sender_id == u.id, Connection.receiver_id == u.id)
        )
    ).all()
    return [
        {
            "id": c.id,
            "sender_id": c.sender_id,
            "receiver_id": c.receiver_id,
            "kind": c.kind,
            "status": c.status,
            "peer_name": db.get(
                User, c.receiver_id if c.sender_id == u.id else c.sender_id
            ).name,
        }
        for c in items
        if not blocked(db, c.sender_id, c.receiver_id) and c.status != "closed"
    ]


@app.post("/connections/{connection_id}/accept")
def accept_connection(
    connection_id: int,
    u: User = Depends(current_user),
    db: Session = Depends(db_session),
):
    c = db.get(Connection, connection_id)
    if not c or c.receiver_id != u.id:
        raise HTTPException(404, "Request not found")
    validate_pair(db, u, c.sender_id, c.kind)
    if c.status != "pending":
        raise HTTPException(409, "Request already answered")
    c.status = "accepted"
    db.commit()
    return {"status": "accepted"}


@app.get("/books")
def list_books(
    q: str = "", u: User = Depends(current_user), db: Session = Depends(db_session)
):
    require_member(db, u)
    query = (
        select(Book)
        .join(User, Book.owner_id == User.id)
        .where(Book.available == True, User.college == u.college)
    )
    if q:
        query = query.where(Book.title.ilike(f"%{q[:80]}%"))
    return [
        {
            "id": b.id,
            "owner_id": b.owner_id,
            "title": b.title,
            "author": b.author,
            "condition": b.condition,
            "price": b.price,
        }
        for b in db.scalars(query.order_by(Book.id.desc()).limit(100))
        if not blocked(db, u.id, b.owner_id)
    ]


@app.post("/books", status_code=201)
def add_book(
    data: BookInput, u: User = Depends(current_user), db: Session = Depends(db_session)
):
    require_member(db, u)
    b = Book(owner_id=u.id, **data.model_dump())
    db.add(b)
    db.commit()
    db.refresh(b)
    return {"id": b.id}


@app.post("/books/{book_id}/reserve")
def reserve_book(
    book_id: int, u: User = Depends(current_user), db: Session = Depends(db_session)
):
    b = db.get(Book, book_id)
    if not b or not b.available:
        raise HTTPException(404, "Book unavailable")
    if b.owner_id == u.id:
        raise HTTPException(400, "Cannot reserve own book")
    validate_pair(db, u, b.owner_id, "study")
    changed = db.execute(
        update(Book)
        .where(Book.id == book_id, Book.available == True)
        .values(available=False)
    )
    if not changed.rowcount:
        raise HTTPException(409, "Already reserved")
    db.commit()
    return {"status": "reserved", "book_id": b.id}


@app.get("/messages/{peer_id}")
def messages(
    peer_id: int, u: User = Depends(current_user), db: Session = Depends(db_session)
):
    if blocked(db, u.id, peer_id) or not accepted(db, u.id, peer_id):
        raise HTTPException(403, "Accepted connection required")
    items = db.scalars(
        select(Message)
        .where(
            or_(
                (Message.sender_id == u.id) & (Message.receiver_id == peer_id),
                (Message.sender_id == peer_id) & (Message.receiver_id == u.id),
            )
        )
        .order_by(Message.id.desc())
        .limit(100)
    ).all()
    return [
        {
            "id": m.id,
            "sender_id": m.sender_id,
            "receiver_id": m.receiver_id,
            "body": m.body,
            "mime": db.scalar(
                select(Attachment.mime).where(Attachment.message_id == m.id)
            ),
            "created_at": m.created_at.isoformat(),
        }
        for m in reversed(items)
    ]


@app.post("/messages", status_code=201)
def send_message(
    data: MessageInput,
    u: User = Depends(current_user),
    db: Session = Depends(db_session),
):
    if blocked(db, u.id, data.receiver_id) or not accepted(db, u.id, data.receiver_id):
        raise HTTPException(403, "Accepted connection required")
    m = Message(sender_id=u.id, receiver_id=data.receiver_id, body=data.body)
    db.add(m)
    db.commit()
    db.refresh(m)
    return {"id": m.id}


@app.get("/communities")
def communities(u: User = Depends(current_user), db: Session = Depends(db_session)):
    require_member(db, u)
    return [
        {"id": c.id, "name": c.name, "description": c.description}
        for c in db.scalars(
            select(Community)
            .join(User, Community.owner_id == User.id)
            .where(User.college == u.college)
            .order_by(Community.id.desc())
            .limit(100)
        )
    ]


@app.post("/communities", status_code=201)
def create_community(
    data: CommunityInput,
    u: User = Depends(current_user),
    db: Session = Depends(db_session),
):
    require_member(db, u)
    c = Community(owner_id=u.id, **data.model_dump())
    db.add(c)
    db.commit()
    db.refresh(c)
    db.add(Membership(user_id=u.id, community_id=c.id))
    db.commit()
    return {"id": c.id}


@app.post("/communities/{community_id}/join")
def join_community(
    community_id: int,
    u: User = Depends(current_user),
    db: Session = Depends(db_session),
):
    if not db.get(Community, community_id):
        raise HTTPException(404, "Community not found")
    require_member(db, u)
    if db.get(User, db.get(Community, community_id).owner_id).college != u.college:
        raise HTTPException(403, "Campus membership required")
    if not db.scalar(
        select(Membership).where(
            Membership.user_id == u.id, Membership.community_id == community_id
        )
    ):
        db.add(Membership(user_id=u.id, community_id=community_id))
        db.commit()
    return {"status": "joined"}


@app.post("/reports", status_code=201)
def report_user(
    data: ReportInput,
    u: User = Depends(current_user),
    db: Session = Depends(db_session),
):
    if not db.get(User, data.target_id) or data.target_id == u.id:
        raise HTTPException(400, "Invalid target")
    r = Report(reporter_id=u.id, **data.model_dump())
    db.add(r)
    db.commit()
    return {"status": "submitted"}


@app.post("/blocks/{target_id}")
def block_user(
    target_id: int, u: User = Depends(current_user), db: Session = Depends(db_session)
):
    if not db.get(User, target_id) or target_id == u.id:
        raise HTTPException(400, "Invalid target")
    if not db.scalar(
        select(Block).where(Block.blocker_id == u.id, Block.blocked_id == target_id)
    ):
        db.add(Block(blocker_id=u.id, blocked_id=target_id))
        db.commit()
    return {"status": "blocked"}


@app.get("/admin/reports")
def admin_reports(u: User = Depends(current_user), db: Session = Depends(db_session)):
    if u.role != "admin":
        raise HTTPException(403, "Admin role required")
    return [
        {
            "id": r.id,
            "reporter_id": r.reporter_id,
            "target_id": r.target_id,
            "reason": r.reason,
            "status": r.status,
        }
        for r in db.scalars(select(Report).limit(100))
    ]


def verification_view(v):
    return (
        dict(
            dob=str(v.dob),
            college_ok=v.college_ok,
            adult_checked=v.adult_checked,
            gender=v.gender,
            preferences=v.preferences,
            dating=v.dating,
        )
        if v
        else {}
    )


def require_member(db, u):
    v = db.get(Verification, u.id)
    email = db.get(EmailChallenge, u.id)
    if not email or not email.verified:
        raise HTTPException(403, "Verify your email in Profile")
    if not v or not v.college_ok or not u.college.strip():
        raise HTTPException(
            403, "Save your college and request verification under Profile"
        )
    return v


def validate_pair(db, u, peer, kind):
    if kind not in ("study", "friend", "dating"):
        raise HTTPException(422, "Unknown connection mode")
    other = db.get(User, peer)
    if (
        not other
        or u.id == peer
        or u.college != other.college
        or blocked(db, u.id, peer)
    ):
        raise HTTPException(403, "Connection unavailable")
    a = require_member(db, u)
    b = require_member(db, other)
    if kind == "dating" and not compatible(a, b):
        raise HTTPException(403, "Dating preferences or eligibility do not match")


@app.put("/profile/preferences")
def preferences(body: Settings, u=Depends(current_user), db=Depends(db_session)):
    from datetime import date

    if not date(1900, 1, 1) <= body.dob <= date.today() or not u.college.strip():
        raise HTTPException(422, "Save your college and enter a valid date of birth")
    v = db.get(Verification, u.id)
    if not v:
        v = Verification(user_id=u.id)
        db.add(v)
    if v.dob != body.dob:
        v.adult_checked = False
    if body.dating and not (v.college_ok and v.adult_checked and adult(body.dob)):
        raise HTTPException(403, "Verify college and adult eligibility first")
    for k, value in body.model_dump().items():
        setattr(v, k, value)
    db.commit()
    return verification_view(v)


@app.post("/connections/{cid}/close")
def close(cid: int, u=Depends(current_user), db=Depends(db_session)):
    c = db.get(Connection, cid)
    if not c or u.id not in (c.sender_id, c.receiver_id):
        raise HTTPException(404, "Connection unavailable")
    c.status = "closed"
    db.commit()
    return {"closed": True}


@app.websocket("/live/{peer}")
async def live(ws: WebSocket, peer: int):
    import asyncio

    token = ws.headers.get("authorization", "").removeprefix("Bearer ")

    def snapshot():
        with SessionLocal() as db:
            u = current_user(
                HTTPAuthorizationCredentials(scheme="Bearer", credentials=token), db
            )
            return messages(peer, u, db)

    try:
        rows = await asyncio.to_thread(snapshot)
        await ws.accept()
        while True:
            await ws.send_json(rows)
            await asyncio.sleep(2)
            rows = await asyncio.to_thread(snapshot)
    except HTTPException:
        await ws.close(code=1008)
    except (WebSocketDisconnect, OSError, RuntimeError):
        pass


from fastapi import Request
from fastapi.responses import HTMLResponse
from pathlib import Path


@app.get("/admin", response_class=HTMLResponse)
def dashboard():
    return (Path(__file__).parent / "admin.html").read_text()


def operator(req: Request):
    import secrets

    k = os.getenv("MODERATOR_TOKEN", "")
    if len(k) < 32 or not secrets.compare_digest(
        req.headers.get("authorization", ""), "Bearer " + k
    ):
        raise HTTPException(403, "Moderator only")


@app.get("/moderation/queue", dependencies=[Depends(operator)])
def queue(db=Depends(db_session)):
    return [
        dict(id=u.id, name=u.name, college=u.college, **verification_view(v))
        for u, v in db.execute(
            select(User, Verification)
            .join(Verification, Verification.user_id == User.id)
            .limit(150)
        )
    ]


class Decision(BaseModel):
    adult_verified: bool = False


class Audit(Base):
    __tablename__ = "moderation_actions"
    id = Column(Integer, primary_key=True)
    student = Column(Integer)
    action = Column(String(80))
    created = Column(
        DateTime(timezone=True), default=lambda: datetime.now(timezone.utc)
    )


@app.post("/moderation/verify/{uid}", dependencies=[Depends(operator)])
def verify(uid: int, b: Decision, db=Depends(db_session)):
    v = db.get(Verification, uid)
    if not v:
        raise HTTPException(404, "No request")
    if b.adult_verified and not adult(v.dob):
        raise HTTPException(422, "Student is under 18")
    v.college_ok = True
    v.adult_checked = b.adult_verified
    db.add(
        Audit(student=uid, action="college and age" if b.adult_verified else "college")
    )
    db.commit()
    return {"ok": True}


from fastapi import UploadFile, File, Response
from sqlalchemy import LargeBinary


class Attachment(Base):
    __tablename__ = "message_files"
    message_id = Column(Integer, ForeignKey("messages.id"), primary_key=True)
    mime = Column(String(50), nullable=False)
    data = Column(LargeBinary, nullable=False)


def sanitize(data):
    from io import BytesIO
    from PIL import Image, ImageOps
    from pypdf import PdfReader, PdfWriter

    if len(data) > 4 * 1024 * 1024:
        raise ValueError()
    if data.startswith(b"%PDF-"):
        pdf = PdfReader(BytesIO(data), strict=True)
        if pdf.is_encrypted or not 1 <= len(pdf.pages) <= 100:
            raise ValueError()
        writer = PdfWriter()
        for page in pdf.pages:
            writer.add_page(page, excluded_keys=["/Annots", "/AA", "/OpenAction"])
        out = BytesIO()
        writer.write(out)
        if out.tell() > 5 * 1024 * 1024:
            raise ValueError()
        return "application/pdf", out.getvalue()
    with Image.open(BytesIO(data), formats=["JPEG", "PNG"]) as img:
        if img.width * img.height > 12000000:
            raise ValueError()
        img = ImageOps.exif_transpose(img).convert("RGB")
        img.thumbnail((1600, 1600))
        out = BytesIO()
        img.save(out, "JPEG", quality=82)
        return "image/jpeg", out.getvalue()


@app.post("/files/{peer}", status_code=201)
def share_file(
    peer: int,
    file: UploadFile = File(...),
    u=Depends(current_user),
    db=Depends(db_session),
):
    if not accepted(db, u.id, peer):
        raise HTTPException(403, "Accepted connection required")
    try:
        mime, data = sanitize(file.file.read(4 * 1024 * 1024 + 1))
    except Exception:
        raise HTTPException(422, "Choose a JPEG, PNG or PDF under 4 MB")
    m = Message(
        sender_id=u.id,
        receiver_id=peer,
        body="Shared study notes" if mime == "application/pdf" else "Shared image",
    )
    db.add(m)
    db.flush()
    db.add(Attachment(message_id=m.id, mime=mime, data=data))
    db.commit()
    return {"id": m.id}


@app.get("/files/{mid}")
def download(mid: int, u=Depends(current_user), db=Depends(db_session)):
    m = db.get(Message, mid)
    if (
        not m
        or u.id not in (m.sender_id, m.receiver_id)
        or not accepted(db, m.sender_id, m.receiver_id)
    ):
        raise HTTPException(404, "File unavailable")
    a = db.get(Attachment, mid)
    if not a:
        raise HTTPException(404, "File unavailable")
    return Response(
        a.data,
        media_type=a.mime,
        headers={
            "Cache-Control": "no-store",
            "Content-Disposition": "attachment",
            "X-Content-Type-Options": "nosniff",
        },
    )


from datetime import date
from sqlalchemy import update


class EmailChallenge(Base):
    __tablename__ = "email_verifications"
    user_id = Column(Integer, ForeignKey("users.id"), primary_key=True)
    digest = Column(String(64))
    issued = Column(Integer, nullable=False, default=0)
    attempts = Column(Integer, nullable=False, default=0)
    verified = Column(Boolean, nullable=False, default=False)


class Event(Base):
    __tablename__ = "events"
    id = Column(Integer, primary_key=True)
    campus = Column(String(160), nullable=False, index=True)
    owner = Column(Integer, ForeignKey("users.id"))
    title = Column(String(140), nullable=False)
    place = Column(String(180), nullable=False)
    starts = Column(DateTime(timezone=True), nullable=False)


class RSVP(Base):
    __tablename__ = "event_registrations"
    event = Column(Integer, ForeignKey("events.id"), primary_key=True)
    student = Column(Integer, ForeignKey("users.id"), primary_key=True)


def otp_hash(uid, code):
    import hmac, hashlib

    return hmac.new(
        SECRET.encode(), f"{uid}:{code}".encode(), hashlib.sha256
    ).hexdigest()


@app.post("/email/send")
def email_send(u=Depends(current_user), db=Depends(db_session)):
    import secrets, time, smtplib, ssl
    from email.message import EmailMessage

    v = db.get(EmailChallenge, u.id)
    if not v:
        v = EmailChallenge(user_id=u.id, issued=0, verified=False)
        db.add(v)
    if v.verified:
        return {"verified": True}
    if time.time() - v.issued < 60:
        raise HTTPException(429, "Wait one minute to resend")
    code = f"{secrets.randbelow(1000000):06d}"
    if os.getenv("LOCAL_MAIL") == "1":
        p = Path("dev-mail")
        p.mkdir(mode=0o700, exist_ok=True)
        (p / f"{u.id}.txt").write_text(u.email + "\n" + code)
    elif os.getenv("RESEND_API_KEY"):
        import httpx
        try:
            response=httpx.post("https://api.resend.com/emails",headers={"Authorization":"Bearer "+os.environ["RESEND_API_KEY"]},json={"from":os.environ["SMTP_FROM"],"to":[u.email],"subject":"CampusVibe verification","text":"Your 10-minute CampusVibe code is "+code},timeout=12)
            response.raise_for_status()
        except (httpx.HTTPError, KeyError):
            raise HTTPException(503,"Email delivery is unavailable")
    elif os.getenv("SMTP_HOST"):
        mail = EmailMessage()
        mail["To"] = u.email
        mail["From"] = os.environ["SMTP_FROM"]
        mail["Subject"] = "CampusVibe verification"
        mail.set_content("Your 10-minute code is " + code)
        with smtplib.SMTP(
            os.environ["SMTP_HOST"], int(os.getenv("SMTP_PORT", "587")), timeout=15
        ) as smtp:
            smtp.starttls(context=ssl.create_default_context())
            smtp.login(os.environ["SMTP_USER"], os.environ["SMTP_PASSWORD"])
            smtp.send_message(mail)
    else:
        raise HTTPException(503, "Configure email delivery")
    v.digest = otp_hash(u.id, code)
    v.issued = int(time.time())
    v.attempts = 0
    db.commit()
    return {"sent": True}


class OTP(BaseModel):
    code: str = Field(pattern=r"^\d{6}$")


@app.post("/email/confirm")
def email_confirm(data: OTP, u=Depends(current_user), db=Depends(db_session)):
    import time, hmac

    v = db.get(EmailChallenge, u.id)
    if not v:
        raise HTTPException(400, "Request a code")
    if v.verified:
        return {"verified": True}
    claim = db.execute(
        update(EmailChallenge)
        .where(
            EmailChallenge.user_id == u.id,
            EmailChallenge.attempts < 5,
            EmailChallenge.issued > int(time.time()) - 600,
        )
        .values(attempts=EmailChallenge.attempts + 1)
    )
    if not claim.rowcount:
        raise HTTPException(400, "Code expired")
    if not hmac.compare_digest(otp_hash(u.id, data.code), v.digest):
        db.commit()
        raise HTTPException(400, "Incorrect code")
    v.verified = True
    v.digest = ""
    db.commit()
    return {"verified": True}


class EventInput(BaseModel):
    title: str = Field(min_length=2, max_length=140)
    place: str = Field(min_length=2, max_length=180)
    starts: datetime


@app.post("/events", status_code=201)
def create_event(b: EventInput, u=Depends(current_user), db=Depends(db_session)):
    require_member(db, u)
    if not b.starts.tzinfo or b.starts <= datetime.now(timezone.utc):
        raise HTTPException(422, "Choose a future time")
    e = Event(
        owner=u.id,
        campus=u.college,
        title=b.title,
        place=b.place,
        starts=b.starts.astimezone(timezone.utc),
    )
    db.add(e)
    db.commit()
    return {"id": e.id}


@app.get("/events")
def events(u=Depends(current_user), db=Depends(db_session)):
    require_member(db, u)
    return [
        {
            "id": e.id,
            "title": e.title,
            "place": e.place,
            "starts": e.starts.replace(tzinfo=timezone.utc).isoformat(),
            "going": bool(db.get(RSVP, (e.id, u.id))),
        }
        for e in db.scalars(
            select(Event)
            .where(Event.campus == u.college, Event.starts > datetime.now(timezone.utc))
            .order_by(Event.starts)
            .limit(100)
        )
        if not blocked(db, e.owner, u.id)
    ]


@app.post("/events/{eid}/rsvp")
def join_event(eid: int, u=Depends(current_user), db=Depends(db_session)):
    require_member(db, u)
    e = db.get(Event, eid)
    if not e or e.campus != u.college or blocked(db, u.id, e.owner):
        raise HTTPException(404, "Event unavailable")
    if not db.get(RSVP, (eid, u.id)):
        db.add(RSVP(event=eid, student=u.id))
        db.commit()
    return {"going": True}


@app.get("/account/export")
def export_account(u=Depends(current_user), db=Depends(db_session)):
    return {
        "profile": profile_me(u, db),
        "connections": connections(u, db),
        "books": [
            {"title": b.title, "author": b.author, "price": b.price}
            for b in db.scalars(select(Book).where(Book.owner_id == u.id))
        ],
        "sent_messages": [
            {
                "id": m.id,
                "to": m.receiver_id,
                "body": m.body,
                "created": m.created_at.isoformat(),
            }
            for m in db.scalars(select(Message).where(Message.sender_id == u.id))
        ],
    }


@app.delete("/account")
def delete_account(u=Depends(current_user), db=Depends(db_session)):
    from sqlalchemy import delete

    uid = u.id
    db.execute(delete(GoogleIdentity).where(GoogleIdentity.user_id==uid))
    db.execute(
        delete(FocusSession).where(
            or_(FocusSession.student_a == uid, FocusSession.student_b == uid)
        )
    )
    db.execute(
        delete(CirclePost).where(
            or_(
                CirclePost.author_id == uid,
                CirclePost.community_id.in_(
                    select(Community.id).where(Community.owner_id == uid)
                ),
            )
        )
    )

    pair = or_(Message.sender_id == uid, Message.receiver_id == uid)
    db.execute(
        delete(Attachment).where(
            Attachment.message_id.in_(select(Message.id).where(pair))
        )
    )
    db.execute(
        delete(RSVP).where(
            or_(
                RSVP.student == uid,
                RSVP.event.in_(select(Event.id).where(Event.owner == uid)),
            )
        )
    )
    db.execute(
        delete(Membership).where(
            or_(
                Membership.user_id == uid,
                Membership.community_id.in_(
                    select(Community.id).where(Community.owner_id == uid)
                ),
            )
        )
    )
    for table, predicate in [
        (Message, pair),
        (Event, Event.owner == uid),
        (Community, Community.owner_id == uid),
        (Book, Book.owner_id == uid),
        (Connection, or_(Connection.sender_id == uid, Connection.receiver_id == uid)),
        (Report, or_(Report.target_id == uid, Report.reporter_id == uid)),
        (Block, or_(Block.blocker_id == uid, Block.blocked_id == uid)),
        (EmailChallenge, EmailChallenge.user_id == uid),
        (Verification, Verification.user_id == uid),
        (Interest, Interest.user_id == uid),
    ]:
        db.execute(delete(table).where(predicate))
    db.delete(u)
    db.commit()
    if os.getenv("LOCAL_MAIL") == "1":
        (Path("dev-mail") / f"{uid}.txt").unlink(missing_ok=True)
    return {"deleted": True}


from quotas import allowed
from fastapi.responses import JSONResponse


@app.middleware("http")
async def write_limits(request: Request, call_next):
    import asyncio

    if request.method in ("POST", "PATCH", "PUT", "DELETE"):
        client = request.client.host if request.client else "local"
        ok = await asyncio.to_thread(allowed, "write:" + client, 240, 60)
        if request.url.path.startswith("/auth/"):
            ok = ok and await asyncio.to_thread(allowed, "auth:" + client, 50, 300)
        if not ok:
            return JSONResponse(
                {"detail": "Rate limit reached. Try again later."}, status_code=429
            )
    return await call_next(request)


class StudyPrompt(BaseModel):
    question: str = Field(min_length=2, max_length=3000)


@app.post("/study/assistant")
def tutor(b: StudyPrompt, u=Depends(current_user), db=Depends(db_session)):
    import httpx

    require_member(db, u)
    if not os.getenv("AI_API_KEY") or not os.getenv("AI_MODEL"):
        raise HTTPException(503, "The campus operator has not connected an AI provider")
    if not allowed("ai:user:" + str(u.id), 5, 86400) or not allowed(
        "ai:campus", int(os.getenv("AI_DAILY_LIMIT", "50")), 86400
    ):
        raise HTTPException(429, "Daily AI request budget reached")
    try:
        r = httpx.post(
            os.getenv("AI_BASE_URL", "https://api.openai.com/v1").rstrip("/")
            + "/chat/completions",
            headers={"Authorization": "Bearer " + os.environ["AI_API_KEY"]},
            json={
                "model": os.environ["AI_MODEL"],
                "max_tokens": 500,
                "messages": [
                    {
                        "role": "system",
                        "content": "Tutor the student. Explain concepts, create revision plans, flashcards or quizzes as requested.",
                    },
                    {"role": "user", "content": b.question},
                ],
            },
            timeout=20,
        )
        r.raise_for_status()
        return {"answer": r.json()["choices"][0]["message"]["content"]}
    except (ValueError, KeyError, IndexError, httpx.HTTPError):
        raise HTTPException(502, "Study provider unavailable")


class CirclePost(Base):
    __tablename__ = "posts"
    id = Column(Integer, primary_key=True)
    community_id = Column(
        Integer, ForeignKey("communities.id"), index=True, nullable=False
    )
    author_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    body = Column(String(3000), nullable=False)


class PostInput(BaseModel):
    body: str = Field(min_length=1, max_length=3000)


def circle_member(db, u, cid):
    require_member(db, u)
    circle = db.get(Community, cid)
    if (
        not circle
        or db.get(User, circle.owner_id).college != u.college
        or blocked(db, u.id, circle.owner_id)
    ):
        raise HTTPException(404, "Circle unavailable")
    if not db.scalar(
        select(Membership).where(
            Membership.user_id == u.id, Membership.community_id == cid
        )
    ):
        raise HTTPException(403, "Join the circle first")


@app.get("/communities/{cid}/posts")
def read_circle(cid: int, u=Depends(current_user), db=Depends(db_session)):
    circle_member(db, u, cid)
    rows = db.scalars(
        select(CirclePost)
        .where(CirclePost.community_id == cid)
        .order_by(CirclePost.id.desc())
        .limit(100)
    )
    return [
        {"id": p.id, "name": db.get(User, p.author_id).name, "body": p.body}
        for p in rows
        if not blocked(db, u.id, p.author_id)
    ]


@app.post("/communities/{cid}/posts", status_code=201)
def add_post(cid: int, b: PostInput, u=Depends(current_user), db=Depends(db_session)):
    circle_member(db, u, cid)
    p = CirclePost(community_id=cid, author_id=u.id, body=b.body)
    db.add(p)
    db.commit()
    return {"id": p.id}


class FocusSession(Base):
    __tablename__ = "study_sessions"
    id = Column(Integer, primary_key=True)
    student_a = Column(Integer, ForeignKey("users.id"), nullable=False)
    student_b = Column(Integer, ForeignKey("users.id"), nullable=False)
    ends = Column(Integer, default=0)
    goal = Column(String(240), default="")
    completed = Column(Boolean, default=False)
    __table_args__ = (UniqueConstraint("student_a", "student_b"),)


class GoalInput(BaseModel):
    goal: str = Field(min_length=1, max_length=240)


def focus_row(db, u, peer):
    if not accepted(db, u.id, peer):
        raise HTTPException(403, "Accepted connection required")
    a, b = sorted((u.id, peer))
    row = db.scalar(
        select(FocusSession).where(
            FocusSession.student_a == a, FocusSession.student_b == b
        )
    )
    if not row:
        row = FocusSession(student_a=a, student_b=b)
        db.add(row)
        try:
            db.commit()
        except Exception:
            db.rollback()
            row = db.scalar(
                select(FocusSession).where(
                    FocusSession.student_a == a, FocusSession.student_b == b
                )
            )
            if not row:
                raise
    return row


@app.get("/study/{peer}/session")
def focus(peer: int, u=Depends(current_user), db=Depends(db_session)):
    f = focus_row(db, u, peer)
    return {"ends": f.ends, "goal": f.goal, "completed": f.completed}


@app.post("/study/{peer}/start")
def start_focus(peer: int, u=Depends(current_user), db=Depends(db_session)):
    import time

    f = focus_row(db, u, peer)
    ts = int(time.time())
    db.execute(
        update(FocusSession)
        .where(FocusSession.id == f.id, FocusSession.ends <= ts)
        .values(ends=ts + 1500)
    )
    db.commit()
    return {"ends": f.ends}


@app.put("/study/{peer}/goal")
def goal(peer: int, b: GoalInput, u=Depends(current_user), db=Depends(db_session)):
    f = focus_row(db, u, peer)
    f.goal = b.goal
    f.completed = False
    db.commit()
    return {"saved": True}


@app.post("/study/{peer}/complete")
def goal_done(peer: int, u=Depends(current_user), db=Depends(db_session)):
    f = focus_row(db, u, peer)
    f.completed = True
    db.commit()
    return {"done": True}

class GoogleIdentity(Base):
    __tablename__="google_identities"
    subject=Column(String(255),primary_key=True)
    user_id=Column(Integer,ForeignKey("users.id",ondelete="CASCADE"),unique=True,nullable=False)
class GoogleCredentials(BaseModel):
    id_token:str=Field(min_length=20,max_length=8192)

@app.get("/mobile/config")
def mobile_config():
    return {"app":"CampusVibe","version":3,"google_client_id":os.getenv("GOOGLE_WEB_CLIENT_ID",""),"email_signup":os.getenv("LOCAL_MAIL")=="1" or bool(os.getenv("SMTP_FROM") and (os.getenv("RESEND_API_KEY") or os.getenv("SMTP_HOST")))}

def google_claims(token,audience):
    from google.oauth2.id_token import verify_oauth2_token
    from google.auth.transport.requests import Request as GoogleRequest
    from google.auth.exceptions import TransportError
    try:return verify_oauth2_token(token,GoogleRequest(),audience=audience)
    except TransportError:raise HTTPException(503,"Google verification temporarily unavailable")
    except ValueError:raise HTTPException(401,"Google sign-in could not be verified")

@app.post("/auth/google")
def google_auth(body:GoogleCredentials,db=Depends(db_session)):
    import secrets
    from sqlalchemy.exc import IntegrityError
    audience=os.getenv("GOOGLE_WEB_CLIENT_ID")
    if not audience:raise HTTPException(503,"Google sign-in has not been configured")
    claims=google_claims(body.id_token,audience)
    email=str(claims.get("email","")).lower()
    sub=claims.get("sub")
    if not sub or not email or claims.get("email_verified") is not True:raise HTTPException(403,"A verified Google email is required")
    identity=db.get(GoogleIdentity,sub)
    if identity:return session_for(db.get(User,identity.user_id))
    if db.scalar(select(User.id).where(User.email==email)):raise HTTPException(409,"Use the original sign-in method for this email")
    u=User(name=str(claims.get("name") or email.split("@")[0])[:120],email=email,password_hash=password_hash.hash(secrets.token_urlsafe(48)))
    try:
        db.add(u);db.flush()
        db.add(GoogleIdentity(subject=sub,user_id=u.id))
        db.add(EmailChallenge(user_id=u.id,verified=True))
        db.commit()
    except IntegrityError:
        db.rollback()
        identity=db.get(GoogleIdentity,sub)
        if identity:return session_for(db.get(User,identity.user_id))
        raise HTTPException(409,"Use the original sign-in method for this email")
    return session_for(u)
