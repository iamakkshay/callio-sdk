"""One class per API namespace, mirroring /api/v1."""
from __future__ import annotations

import shutil
from datetime import datetime
from typing import IO, TYPE_CHECKING, Any, Dict, Iterator, List, Optional, Sequence, Union, cast
from urllib.parse import quote

from .errors import ConflictError, ValidationError
from .types import (CallioEvent, CdrPage, CreatedUser, ErasureResult, EventPage, Group, Ok, Order, Recording, Token,
                    Transcript, User, UserToken)

if TYPE_CHECKING:
    from ._http import HttpClient

_UNSET: Any = object()


def _seg(value: str) -> str:
    if not isinstance(value, str) or not value:
        raise TypeError("Callio: an id / username is required")
    if value in (".", ".."):
        # quote() leaves "." alone, and a "." or ".." segment would be resolved as a relative path.
        raise ValidationError(f'Callio: "{value}" is not a valid id / username')
    return quote(value, safe="")


def _drop(**kw: Any) -> Dict[str, Any]:
    """Keyword arguments that were passed (``_UNSET`` means "leave out"; None is sent as null)."""
    return {k: v for k, v in kw.items() if v is not _UNSET}


def _reason(reason: str) -> str:
    r = str(reason or "").strip()
    if len(r) < 5:
        raise ValueError("Callio: a reason of at least 5 characters is required to fetch a recording")
    return r


class Users:
    def __init__(self, http: "HttpClient") -> None:
        self._http = http

    def list(self, *, q: Optional[str] = None, type: Optional[str] = None, status: Optional[str] = None,
             segment: Optional[str] = None, limit: Optional[int] = None) -> List[User]:
        """Search users. ``type``: customer | agent; ``status``: active | disabled."""
        r = self._http.request("GET", "/api/v1/users", query={"q": q, "type": type, "status": status, "segment": segment, "limit": limit})
        return cast(List[User], r["users"])

    def create(self, username: str, *, display_name: Optional[str] = None, user_type: Optional[str] = None,
               login_password: Optional[str] = None, phone: Optional[str] = None) -> CreatedUser:
        """Raises ConflictError (409) if the username exists, PermissionDeniedError (403) at the seat quota."""
        body = {"username": username, "displayName": display_name, "userType": user_type, "loginPassword": login_password, "phone": phone}
        r = self._http.request("POST", "/api/v1/users", body={k: v for k, v in body.items() if v is not None})
        return cast(CreatedUser, r["user"])

    def get(self, username: str) -> User:
        return cast(User, self._http.request("GET", f"/api/v1/users/{_seg(username)}")["user"])

    def update(self, username: str, *, display_name: Any = _UNSET, user_type: Any = _UNSET, disabled: Any = _UNSET,
               segment: Any = _UNSET, phone: Any = _UNSET) -> User:
        """Changing the type or disabling ends the user's sessions. Pass None to clear segment / phone."""
        body = _drop(displayName=display_name, userType=user_type, disabled=disabled, segment=segment, phone=phone)
        return cast(User, self._http.request("PATCH", f"/api/v1/users/{_seg(username)}", body=body)["user"])

    def disable(self, username: str) -> User:
        return self.update(username, disabled=True)

    def enable(self, username: str) -> User:
        return self.update(username, disabled=False)

    def sign_out(self, username: str) -> Ok:
        """End every session the user has open."""
        return cast(Ok, self._http.request("POST", f"/api/v1/users/{_seg(username)}/sign-out"))

    def export(self, username: str) -> Dict[str, Any]:
        """PDPL access request: everything held about the user."""
        return cast(Dict[str, Any], self._http.request("GET", f"/api/v1/users/{_seg(username)}/export"))

    def delete(self, username: str, *, reason: str) -> ErasureResult:
        """PDPL erasure: deletes the account and its data (recordings on legal hold are kept). Irreversible."""
        return cast(ErasureResult, self._http.request("DELETE", f"/api/v1/users/{_seg(username)}", body={"reason": reason}))


class Tokens:
    def __init__(self, http: "HttpClient", users: Users) -> None:
        self._http = http
        self._users = users

    def create(self, username: str, *, ttl_sec: Optional[int] = None, device_id: Optional[str] = None) -> Token:
        """A short-lived app token for an existing user (60-3600 s, default 900), for one device: device_id is the
        app's device id (its X-Device-Id); without it the token is tied to the first device that uses it."""
        body: Dict[str, Any] = {"username": username}
        if ttl_sec is not None:
            body["ttlSec"] = ttl_sec
        if device_id is not None:
            body["deviceId"] = device_id
        return cast(Token, self._http.request("POST", "/api/v1/tokens", body=body))

    def for_user(self, username: str, *, display_name: Optional[str] = None, user_type: Optional[str] = None,
                 ttl_sec: Optional[int] = None, phone: Optional[str] = None, device_id: Optional[str] = None) -> UserToken:
        """The common job: make sure the app user exists, then issue their token. Creates the user if
        missing (409 means they already exist, which is fine). An existing user's name and type are left
        as they are; check ``userType`` on the result if it matters."""
        created = False
        try:
            self._users.create(username, display_name=display_name, user_type=user_type, phone=phone)
            created = True
        except ConflictError:
            pass
        t = self.create(username, ttl_sec=ttl_sec, device_id=device_id)
        return cast(UserToken, {**t, "created": created})


class Orders:
    def __init__(self, http: "HttpClient") -> None:
        self._http = http

    def create(self, id: str, *, customer: str, agent: Optional[str] = None, label: Optional[str] = None) -> Order:
        """Raises ConflictError if the id exists, ValidationError for an unknown user or wrong user type."""
        body = {k: v for k, v in {"id": id, "customer": customer, "agent": agent, "label": label}.items() if v is not None}
        return cast(Order, self._http.request("POST", "/api/v1/orders", body=body)["order"])

    def list(self, *, status: Optional[str] = None, user: Optional[str] = None, limit: Optional[int] = None) -> List[Order]:
        return cast(List[Order], self._http.request("GET", "/api/v1/orders", query={"status": status, "user": user, "limit": limit})["orders"])

    def get(self, id: str) -> Order:
        return cast(Order, self._http.request("GET", f"/api/v1/orders/{_seg(id)}")["order"])

    def update(self, id: str, *, agent: Any = _UNSET, status: Any = _UNSET, label: Any = _UNSET) -> Order:
        """Reassign (``agent=...``), unassign (``agent=None``), close / reopen (``status``), relabel."""
        return cast(Order, self._http.request("PATCH", f"/api/v1/orders/{_seg(id)}", body=_drop(agent=agent, status=status, label=label))["order"])

    def assign(self, id: str, agent: Optional[str]) -> Order:
        return self.update(id, agent=agent)

    def close(self, id: str) -> Order:
        return self.update(id, status="closed")

    def reopen(self, id: str) -> Order:
        return self.update(id, status="active")


class RecordingAudio:
    """An open audio download (stereo Ogg/Opus, caller left). Use as a context manager and read it in
    chunks; it is never buffered whole in memory."""

    def __init__(self, resp: Any) -> None:
        self._resp = resp
        self.content_type: str = resp.headers.get("Content-Type") or "audio/ogg"
        n = resp.headers.get("Content-Length")
        self.content_length: Optional[int] = int(n) if n else None

    def read(self, n: int = -1) -> bytes:
        return cast(bytes, self._resp.read(n))

    def iter_bytes(self, chunk_size: int = 64 * 1024) -> Iterator[bytes]:
        while True:
            chunk = self._resp.read(chunk_size)
            if not chunk:
                return
            yield chunk

    def close(self) -> None:
        self._resp.close()

    def __enter__(self) -> "RecordingAudio":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()


class Recordings:
    def __init__(self, http: "HttpClient") -> None:
        self._http = http

    def list(self, *, from_: Union[str, datetime, None] = None, to: Union[str, datetime, None] = None,
             user: Optional[str] = None, call_id: Optional[str] = None, order_id: Optional[str] = None,
             min_duration: Optional[int] = None, max_duration: Optional[int] = None, status: Optional[str] = None,
             limit: Optional[int] = None) -> List[Recording]:
        """Search recordings. ``user`` is either party's extension; durations in seconds; ``status``:
        stored (default) | deleted | all."""
        query = {"from": from_, "to": to, "user": user, "callId": call_id, "orderId": order_id,
                 "minDuration": min_duration, "maxDuration": max_duration, "status": status, "limit": limit}
        return cast(List[Recording], self._http.request("GET", "/api/v1/recordings", query=query)["recordings"])

    def get(self, id: str) -> Recording:
        return cast(Recording, self._http.request("GET", f"/api/v1/recordings/{_seg(id)}")["recording"])

    def audio(self, id: str, *, reason: str) -> RecordingAudio:
        """Open the audio as a stream. The reason (5+ characters) goes into the recording's access trail."""
        resp = self._http.request("GET", f"/api/v1/recordings/{_seg(id)}/audio", query={"reason": _reason(reason)}, stream=True)
        return RecordingAudio(resp)

    def download(self, id: str, dest: Union[str, "IO[bytes]"], *, reason: str) -> int:
        """Stream the audio to a path or a binary file object; returns the number of bytes written."""
        with self.audio(id, reason=reason) as a:
            if isinstance(dest, str):
                with open(dest, "wb") as f:
                    return _copy(a, f)
            return _copy(a, dest)

    def transcript(self, id: str, *, reason: str) -> Transcript:
        """Same rules as the audio. NotFoundError while it is still being transcribed or if there is none."""
        r = self._http.request("GET", f"/api/v1/recordings/{_seg(id)}/transcript", query={"reason": _reason(reason)})
        return cast(Transcript, r["transcript"])


def _copy(a: RecordingAudio, f: "IO[bytes]") -> int:
    n = 0
    for chunk in a.iter_bytes():
        f.write(chunk)
        n += len(chunk)
    return n


class Groups:
    def __init__(self, http: "HttpClient") -> None:
        self._http = http

    def create(self, id: str, *, name: str, members: Sequence[str]) -> Group:
        """2-50 members."""
        return cast(Group, self._http.request("POST", "/api/v1/groups", body={"id": id, "name": name, "members": list(members)})["group"])

    def list(self) -> List[Group]:
        return cast(List[Group], self._http.request("GET", "/api/v1/groups")["groups"])

    def get(self, id: str) -> Group:
        return cast(Group, self._http.request("GET", f"/api/v1/groups/{_seg(id)}")["group"])

    def update(self, id: str, *, name: Optional[str] = None, add: Optional[Sequence[str]] = None,
               remove: Optional[Sequence[str]] = None) -> Group:
        """Rename, add or remove members (added members see messages from when they joined)."""
        body: Dict[str, Any] = {}
        if name is not None:
            body["name"] = name
        if add:
            body["add"] = list(add)
        if remove:
            body["remove"] = list(remove)
        return cast(Group, self._http.request("PATCH", f"/api/v1/groups/{_seg(id)}", body=body)["group"])

    def delete(self, id: str) -> Ok:
        """Deletes the group and its messages."""
        return cast(Ok, self._http.request("DELETE", f"/api/v1/groups/{_seg(id)}"))


class Events:
    def __init__(self, http: "HttpClient") -> None:
        self._http = http

    def list(self, *, after: Optional[int] = None, limit: Optional[int] = None,
             types: Union[str, Sequence[str], None] = None) -> EventPage:
        """One page of the event feed, in order. Pass the returned ``next`` as ``after``."""
        return cast(EventPage, self._http.request("GET", "/api/v1/events", query={"after": after, "limit": limit, "types": types}))

    def iterate(self, *, after: int = 0, limit: Optional[int] = None,
                types: Union[str, Sequence[str], None] = None) -> Iterator[CallioEvent]:
        """Every event after ``after``, page by page, until caught up. Remember the last ``id`` to resume."""
        while True:
            page = self.list(after=after, limit=limit, types=types)
            yield from page["events"]
            if not page["events"] or page["next"] <= after:
                return
            after = page["next"]


class Cdr:
    def __init__(self, http: "HttpClient") -> None:
        self._http = http

    def list(self, *, days: Optional[int] = None, type: Optional[str] = None) -> CdrPage:
        """Call records for the last ``days`` (1-90, default 7): one row per call."""
        return cast(CdrPage, self._http.request("GET", "/api/v1/cdr", query={"days": days, "type": type}))
