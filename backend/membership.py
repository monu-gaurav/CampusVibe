from datetime import date
from pydantic import BaseModel, Field
from typing import Literal
from sqlalchemy import Column, ForeignKey, Integer, String, Boolean, Date, JSON
from fastapi import HTTPException


def define_membership(base):
    class MembershipProfile(base):
        __tablename__ = "student_verifications"
        user_id = Column(Integer, ForeignKey("users.id"), primary_key=True)
        dob = Column(Date, nullable=False)
        college_ok = Column(Boolean, default=False, nullable=False)
        adult_checked = Column(Boolean, default=False, nullable=False)
        gender = Column(String(80), default="Prefer not to say")
        preferences = Column(JSON, default=list)
        dating = Column(Boolean, default=False)

    return MembershipProfile


class Settings(BaseModel):
    dob: date
    gender: Literal[
        "Man", "Woman", "Non-binary", "Self-describe", "Prefer not to say"
    ] = "Prefer not to say"
    preferences: list[
        Literal["Man", "Woman", "Non-binary", "Self-describe", "Everyone"]
    ] = Field(default_factory=list, max_length=5)
    dating: bool = False


def adult(d):
    today = date.today()
    return today.year - d.year - ((today.month, today.day) < (d.month, d.day)) >= 18


def compatible(a, b):
    return bool(
        a
        and b
        and all(
            x.college_ok and x.adult_checked and x.dating and adult(x.dob)
            for x in (a, b)
        )
        and all(
            "Everyone" in x.preferences or y.gender in x.preferences
            for x, y in ((a, b), (b, a))
        )
    )
