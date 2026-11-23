"""Uses a new temporary database per test session."""

import os, tempfile
from pathlib import Path
from datetime import date

root = Path(tempfile.mkdtemp())
os.environ.update(
    LOCAL_MAIL="1",
    CAMPUSVIBE_JWT_SECRET="development-test-key-" * 3,
    MODERATOR_TOKEN="temporary-moderator-" * 3,
    DATABASE_URL=os.getenv(
        "CAMPUS_TEST_DATABASE_URL", "sqlite:///" + str(root / "test.db")
    ),
)
import pytest
from fastapi.testclient import TestClient
import main

c = TestClient(main.app)
op = {"Authorization": "Bearer " + os.environ["MODERATOR_TOKEN"]}


@pytest.fixture(autouse=True)
def clear(tmp_path, monkeypatch):
    from quotas import counts

    counts.clear()
    monkeypatch.chdir(tmp_path)
    main.Base.metadata.drop_all(main.engine)
    main.Base.metadata.create_all(main.engine)


def student(n, dob="2000-04-01"):
    payload = {
        "name": f"Student {n}",
        "email": f"test{n}@example.org",
        "password": "temporary-test-password",
    }
    uid = c.post("/auth/register", json=payload).json()["id"]
    h = {
        "Authorization": "Bearer "
        + c.post("/auth/login", json=payload).json()["access_token"]
    }
    c.patch("/profile/me", json={"college": "GEC Test"}, headers=h)
    assert c.get("/discover", headers=h).status_code == 403
    assert c.post("/email/send", headers=h).status_code == 200
    assert (
        c.post(
            "/email/confirm",
            headers=h,
            json={"code": Path(f"dev-mail/{uid}.txt").read_text().split()[1]},
        ).status_code
        == 200
    )
    assert (
        c.put("/profile/preferences", json={"dob": dob}, headers=h).status_code == 200
    )
    assert c.post(f"/moderation/verify/{uid}", json={}, headers=op).status_code == 200
    return uid, h


def test_discovery_and_consent():
    a, ah = student(1)
    b, bh = student(2)
    c.put("/interests", headers=ah, json={"labels": ["DBMS"]})
    c.put("/interests", headers=bh, json={"labels": ["DBMS"]})
    card = c.get("/discover", headers=ah).json()[0]
    assert card["shared_interests"] == ["dbms"] and "email" not in card
    edge = c.post(
        "/connections", headers=ah, json={"receiver_id": b, "kind": "study"}
    ).json()["id"]
    assert c.post(f"/connections/{edge}/accept", headers=ah).status_code == 404
    assert c.get(f"/messages/{b}", headers=ah).status_code == 403
    c.post(f"/connections/{edge}/accept", headers=bh)
    c.post(
        "/messages", headers=ah, json={"receiver_id": b, "body": "Let's revise trees"}
    )
    with c.websocket_connect(f"/live/{a}", headers=bh) as ws:
        assert ws.receive_json()[0]["body"] == "Let's revise trees"
    c.post(f"/blocks/{a}", headers=bh)
    assert c.get(f"/messages/{b}", headers=ah).status_code == 403


def test_dating_age():
    a, h = student(1, "2014-03-01")
    assert (
        c.post(
            f"/moderation/verify/{a}", json={"adult_verified": True}, headers=op
        ).status_code
        == 422
    )
    assert (
        c.put(
            "/profile/preferences",
            json={"dob": "2014-03-01", "dating": True},
            headers=h,
        ).status_code
        == 403
    )
    assert c.get("/discover?kind=dating", headers=h).status_code == 403


def test_book():
    a, h = student(1)
    b, k = student(2)
    book = c.post(
        "/books", json={"title": "Algorithms", "price": 60}, headers=h
    ).json()["id"]
    assert c.post(f"/books/{book}/reserve", headers=h).status_code == 400
    assert c.post(f"/books/{book}/reserve", headers=k).status_code == 200
    assert c.get("/books", headers=h).json() == []


def test_files():
    from PIL import Image
    from io import BytesIO

    out = BytesIO()
    Image.new("RGB", (10, 10)).save(out, "PNG")
    a, h = student(1)
    b, k = student(2)
    _, third = student(3)
    e = c.post(
        "/connections", headers=h, json={"receiver_id": b, "kind": "study"}
    ).json()["id"]
    c.post(f"/connections/{e}/accept", headers=k)
    assert (
        c.post(
            f"/files/{b}", headers=h, files={"file": ("invalid.jpg", b"no")}
        ).status_code
        == 422
    )
    mid = c.post(
        f"/files/{b}", headers=h, files={"file": ("notes.png", out.getvalue())}
    ).json()["id"]
    assert c.get(f"/files/{mid}", headers=k).headers["content-type"] == "image/jpeg"
    assert c.get(f"/files/{mid}", headers=third).status_code == 404


def test_event_and_disabled_provider():
    a, h = student(1)
    b, k = student(2)
    e = c.post(
        "/events",
        headers=h,
        json={
            "title": "DBMS revision",
            "place": "Library foyer",
            "starts": "2099-02-01T17:00:00+05:30",
        },
    ).json()["id"]
    assert c.post(f"/events/{e}/rsvp", headers=k).status_code == 200
    assert c.get("/events", headers=k).json()[0]["going"]
    assert c.post("/study/assistant", json={"question":"Explain heaps"}).status_code in (401,403)



def test_deletion_and_moderator_auth():
    _, h = student(1)
    assert c.get("/moderation/queue", headers=h).status_code == 403
    assert c.get("/account/export", headers=h).json()["profile"]["email_verified"]
    assert c.delete("/account", headers=h).status_code == 200
    student(2)
    assert c.get("/profile/me", headers=h).status_code == 401


def test_adult_mutual_dating_preferences():
    a, h = student(1)
    b, k = student(2)
    assert c.get("/profile/me", headers=h).json()["email_verified"]
    for uid in (a, b):
        assert (
            c.post(
                f"/moderation/verify/{uid}", json={"adult_verified": True}, headers=op
            ).status_code
            == 200
        )
    for head, gender, pref in [(h, "Man", "Woman"), (k, "Woman", "Woman")]:
        assert (
            c.put(
                "/profile/preferences",
                headers=head,
                json={
                    "dob": "2000-04-01",
                    "dating": True,
                    "gender": gender,
                    "preferences": [pref],
                },
            ).status_code
            == 200
        )
    assert c.get("/discover?kind=dating", headers=h).json() == []
    c.put(
        "/profile/preferences",
        headers=k,
        json={
            "dob": "2000-04-01",
            "dating": True,
            "gender": "Woman",
            "preferences": ["Man"],
        },
    )
    assert c.get("/discover?kind=dating", headers=h).json()[0]["id"] == b


def test_shared_study_and_circle():
    a, h = student(1)
    b, k = student(2)
    cid = c.post("/communities", headers=h, json={"name": "GATE revision"}).json()["id"]
    assert c.get(f"/communities/{cid}/posts", headers=k).status_code == 403
    c.post(f"/communities/{cid}/join", headers=k)
    assert (
        c.post(
            f"/communities/{cid}/posts", headers=h, json={"body": "Revise transactions"}
        ).status_code
        == 201
    )
    assert (
        c.get(f"/communities/{cid}/posts", headers=k).json()[0]["body"]
        == "Revise transactions"
    )
    eid = c.post(
        "/connections", headers=h, json={"receiver_id": b, "kind": "study"}
    ).json()["id"]
    c.post(f"/connections/{eid}/accept", headers=k)
    ends = c.post(f"/study/{b}/start", headers=h).json()["ends"]
    assert c.post(f"/study/{a}/start", headers=k).json()["ends"] == ends
    c.put(f"/study/{b}/goal", headers=h, json={"goal": "Solve five problems"})
    c.post(f"/study/{a}/complete", headers=k)
    assert c.get(f"/study/{b}/session", headers=h).json()["completed"]
    assert c.delete("/account", headers=h).status_code == 200

def test_hosted_google_flow(monkeypatch):
    seen=[]
    monkeypatch.setenv("GOOGLE_WEB_CLIENT_ID","pilot-web-client")
    def local_identity(token,audience):
        seen.append(audience)
        return {"sub":"test-provider-subject","email":"newuser@example.org","email_verified":True,"name":"Google Student"}
    monkeypatch.setattr(main,"google_claims",local_identity)
    data={"id_token":"test-credential-for-controlled-test"}
    one=c.post("/auth/google",json=data)
    assert one.status_code==200 and seen==["pilot-web-client"]
    h={"Authorization":"Bearer "+one.json()["access_token"]}
    profile=c.get("/profile/me",headers=h).json()
    assert profile["email_verified"] and not profile["verification"]
    assert c.get("/discover",headers=h).status_code==403
    assert c.post("/auth/google",json=data).json()["user"]["id"]==profile["id"]
    assert c.delete("/account",headers=h).status_code==200

def test_google_rejects_bad_token_and_existing_password_account(monkeypatch):
    monkeypatch.setenv("GOOGLE_WEB_CLIENT_ID","pilot-web-client")
    data={"id_token":"test-credential-for-controlled-test"}
    monkeypatch.setattr(main,"google_claims",lambda *_:{"email_verified":False})
    assert c.post("/auth/google",json=data).status_code==403
    uid,h=student(4)
    monkeypatch.setattr(main,"google_claims",lambda *_:{"sub":"new-sub","email_verified":True,"email":"test4@example.org"})
    assert c.post("/auth/google",json=data).status_code==409
    assert c.get("/mobile/config").json()["google_client_id"]=="pilot-web-client"

def test_disabled_google(monkeypatch):
    monkeypatch.delenv("GOOGLE_WEB_CLIENT_ID",raising=False)
    assert c.post("/auth/google",json={"id_token":"x"*40}).status_code==503

def test_normal_login_study_chat_without_otp():
    people = []
    for n in (120,121):
        data = {"name":f"Student {n}","email":f"study{n}@example.org","password":"test-password-2026"}
        uid = c.post("/auth/register",json=data).json()["id"]
        h = {"Authorization":"Bearer "+c.post("/auth/login",json=data).json()["access_token"]}
        assert c.put("/profile/study",headers=h,json={"college":"Test Campus","labels":["DBMS"],"visible":True}).status_code == 200
        assert c.get("/discover?kind=dating",headers=h).status_code == 403
        people.append((uid,h))
    (a,ha),(b,hb)=people
    assert c.get("/discover",headers=ha).json()[0]["shared_interests"]==["dbms"]
    assert c.get(f"/messages/{b}",headers=ha).status_code==403
    edge=c.post("/connections",headers=ha,json={"receiver_id":b,"kind":"study"}).json()["id"]
    assert c.post(f"/connections/{edge}/accept",headers=hb).status_code==200
    assert c.post("/messages",headers=ha,json={"receiver_id":b,"body":"Study tonight?"}).status_code==201
    with c.websocket_connect(f"/live/{a}",headers=hb) as ws:
        assert ws.receive_json()[0]["body"]=="Study tonight?"
    c.put("/profile/study",headers=hb,json={"college":"Test Campus","labels":[],"visible":False})
    assert not c.get("/discover",headers=ha).json()
    assert c.get(f"/messages/{b}",headers=ha).status_code==200

def test_portrait_access_follows_discovery_and_blocks():
    from PIL import Image
    import io
    a, ah=student(1)
    b, bh=student(2)
    data=io.BytesIO()
    Image.new("RGB",(12,12)).save(data,"PNG")
    assert c.put("/profile/photo",headers=ah,files={"file":("pic.png",data.getvalue(),"image/png")}).status_code==200
    assert c.get("/discover",headers=bh).json()[0]["photo_version"]
    assert c.get(f"/profile/photo/{a}",headers=bh).headers["content-type"]=="image/jpeg"
    c.post(f"/blocks/{b}",headers=ah)
    assert c.get(f"/profile/photo/{a}",headers=bh).status_code==403
