"""Models returned by the Callio tenant API (/api/v1), as TypedDicts: the values are plain dicts with the
same field names as the JSON on the wire, so they serialise and log as they are."""
from __future__ import annotations

import sys
from typing import Any, Dict, List, Optional, Union

if sys.version_info >= (3, 8):
    from typing import Literal, TypedDict
else:  # pragma: no cover
    from typing_extensions import Literal, TypedDict

UserType = Literal["customer", "agent"]
OrderStatus = Literal["active", "closed"]


class User(TypedDict, total=False):
    username: str
    displayName: Optional[str]
    userType: str
    #: The user's SIP extension.
    extension: str
    segment: Optional[str]
    disabled: bool
    #: Masked phone fallback number (get/create/update only).
    phone: Optional[str]


class CreatedUser(User, total=False):
    #: Returned once, when the user was created without a login password.
    initialPassword: str


class ErasureResult(TypedDict):
    ok: bool
    alias: str
    removed: Dict[str, int]
    recordingsKeptOnLegalHold: List[str]


class Token(TypedDict):
    token: str
    userType: str
    expiresAt: str


class UserToken(Token):
    #: True when for_user() created the user on this call.
    created: bool


class Order(TypedDict):
    id: str
    customer: str
    agent: Optional[str]
    status: str
    label: Optional[str]
    createdAt: str
    updatedAt: str
    closedAt: Optional[str]


class TranscriptInfo(TypedDict):
    status: str
    language: Optional[str]
    error: Optional[str]


class Recording(TypedDict):
    id: str
    tenant: str
    callRef: Optional[str]
    caller: Optional[str]
    callee: Optional[str]
    callType: Optional[str]
    orderId: Optional[str]
    startedAt: Optional[str]
    durationSec: int
    bytes: int
    format: Optional[str]
    status: str
    legalHold: bool
    holdReason: Optional[str]
    retainUntil: Optional[str]
    deletedAt: Optional[str]
    deleteReason: Optional[str]
    createdAt: str
    transcript: Optional[TranscriptInfo]


class Transcript(TypedDict, total=False):
    text: str
    language: Optional[str]
    segments: List[Dict[str, Any]]


class GroupMember(TypedDict):
    username: str
    displayName: Optional[str]
    userType: str
    sipUser: str


class Group(TypedDict):
    id: str
    name: str
    createdAt: str
    members: List[GroupMember]


# "from" is a Python keyword, so these two use the functional form.
CallioEvent = TypedDict("CallioEvent", {
    "id": int, "type": str, "callId": Optional[str], "from": Optional[str], "to": Optional[str],
    "fromType": Optional[str], "toType": Optional[str], "orderId": Optional[str], "at": str, "payload": Dict[str, Any],
})


class EventPage(TypedDict):
    events: List[CallioEvent]
    next: int


CallRecord = TypedDict("CallRecord", {
    "callId": str, "tenant": str, "from": Optional[str], "to": Optional[str], "fromType": Optional[str],
    "toType": Optional[str], "direction": str, "support": bool, "orderId": Optional[str], "entryPoint": Optional[str],
    "outcome": str, "endReason": str, "durationSec": int, "answerSec": Optional[int], "startedAt": Optional[str],
    "answeredAt": Optional[str], "endedAt": Optional[str], "quality": Any, "client": Any,
})


class CdrPage(TypedDict):
    days: int
    calls: List[CallRecord]


class Ok(TypedDict):
    ok: bool


JSON = Union[Dict[str, Any], List[Any], str, int, float, bool, None]
