"""Webhook verification. Callio POSTs JSON events to the organisation's webhook URL with::

    X-Callio-Timestamp: <unix seconds>
    X-Callio-Signature: v1=<hex HMAC-SHA256(secret, timestamp + "." + raw_body)>
    X-NGX-Signature:    sha256=<hex HMAC-SHA256(secret, raw_body)>   (legacy, body only)

and a unique ``id`` per delivery event in the body. Verify the v1 signature (it binds the timestamp, so an
old delivery can't be replayed outside the tolerance window) and de-duplicate on ``id`` inside the window.
Verify the exact bytes received: re-serialising parsed JSON changes them."""
from __future__ import annotations

import hashlib
import hmac
import json
import re
import time
from typing import Any, Dict, Optional, Union

from .errors import CallioError

#: The legacy, body-only signature header.
SIGNATURE_HEADER = "X-NGX-Signature"
TIMESTAMP_HEADER = "X-Callio-Timestamp"
SIGNATURE_V1_HEADER = "X-Callio-Signature"
#: Default accepted clock difference, in seconds.
DEFAULT_TOLERANCE = 300
_SIG = re.compile(r"^sha256=([0-9a-fA-F]{64})$")
_HEX = re.compile(r"^[0-9a-fA-F]{64}$")
_TS = re.compile(r"^[0-9]{1,15}$")

Raw = Union[bytes, bytearray, memoryview, str]
#: A legacy X-NGX-Signature value, or the request headers: any mapping with ``.get`` (a dict, Flask's
#: ``request.headers``, FastAPI/Starlette's ``request.headers``); names are matched case-insensitively.
HeadersOrSignature = Any


class WebhookVerificationError(CallioError):
    """Bad, stale or missing signature, or a body that is not a Callio event."""


def _bytes(raw: Raw) -> bytes:
    return raw.encode("utf-8") if isinstance(raw, str) else bytes(raw)


def sign_webhook(raw_body: Raw, secret: str) -> str:
    """The legacy ``sha256=<hex>`` value Callio sends for this body."""
    return "sha256=" + hmac.new(secret.encode("utf-8"), _bytes(raw_body), hashlib.sha256).hexdigest()


def sign_webhook_v1(raw_body: Raw, secret: str, timestamp: Union[int, str]) -> str:
    """The ``v1=<hex>`` X-Callio-Signature value for this timestamp (unix seconds) and body."""
    msg = str(timestamp).encode("ascii") + b"." + _bytes(raw_body)
    return "v1=" + hmac.new(secret.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def _first(v: Any) -> Optional[str]:
    if isinstance(v, (list, tuple)):
        v = v[0] if v else None
    if isinstance(v, bytes):
        v = v.decode("latin-1")
    return None if v is None else str(v)


def _is_headers(x: Any) -> bool:
    return not isinstance(x, (str, bytes, bytearray, list, tuple)) and x is not None and hasattr(x, "get")


def _header(headers: Any, name: str) -> Optional[str]:
    for n in (name, name.lower()):
        try:
            v = headers.get(n)
        except Exception:  # noqa: BLE001
            v = None
        if v is not None:
            return _first(v)
    items = getattr(headers, "items", None)
    if callable(items):
        low = name.lower()
        for k, v in items():
            if str(k.decode("latin-1") if isinstance(k, bytes) else k).lower() == low:
                return _first(v)
    return None


def _check_legacy(raw_body: Raw, signature_header: Any, secret: str) -> bool:
    m = _SIG.match((_first(signature_header) or "").strip())
    if not m:
        return False
    want = hmac.new(secret.encode("utf-8"), _bytes(raw_body), hashlib.sha256).hexdigest()
    return hmac.compare_digest(m.group(1).lower(), want)


def _check(raw_body: Raw, headers: Any, secret: str, tolerance: float, allow_legacy: bool,
           now: Optional[float]) -> Optional[str]:
    """None when the delivery is authentic and fresh, else the reason it is not."""
    ts = (_header(headers, TIMESTAMP_HEADER) or "").strip()
    if not ts:
        if not allow_legacy:
            return "missing X-Callio-Timestamp (pass allow_legacy=True to accept body-only signatures)"
        return None if _check_legacy(raw_body, _header(headers, SIGNATURE_HEADER), secret) else \
            "bad or missing X-NGX-Signature"
    if not _TS.match(ts):
        return "malformed X-Callio-Timestamp"
    if tolerance is None or tolerance < 0:
        raise ValueError("Callio: tolerance must be a non-negative number of seconds")
    current = time.time() if now is None else now
    if abs(current - int(ts)) > tolerance:
        return "X-Callio-Timestamp is outside the tolerance window"
    want = sign_webhook_v1(raw_body, secret, ts)[3:]
    ok = False
    # Several ``v1=`` entries (comma separated) are allowed, e.g. while a secret is being rotated.
    for part in (_header(headers, SIGNATURE_V1_HEADER) or "").split(","):
        part = part.strip()
        if part.startswith("v1=") and _HEX.match(part[3:]) and hmac.compare_digest(part[3:].lower(), want):
            ok = True
    return None if ok else "bad or missing X-Callio-Signature"


def _reason(raw_body: Raw, headers_or_signature: HeadersOrSignature, secret: str, tolerance: float,
            allow_legacy: bool, now: Optional[float]) -> Optional[str]:
    if not secret:
        raise ValueError("Callio: the webhook secret is required")
    if _is_headers(headers_or_signature):
        return _check(raw_body, headers_or_signature, secret, tolerance, allow_legacy, now)
    # Deprecated form: only the X-NGX-Signature value, i.e. the body-only signature (no replay protection).
    return None if _check_legacy(raw_body, headers_or_signature, secret) else "bad or missing X-NGX-Signature"


def verify_webhook(raw_body: Raw, headers: HeadersOrSignature, secret: str, *, tolerance: float = DEFAULT_TOLERANCE,
                   allow_legacy: bool = False, now: Optional[float] = None) -> bool:
    """True when the delivery is authentic and fresh. Pass the request headers (recommended)::

        verify_webhook(raw_body, request.headers, secret)                 # v1 + 300 s tolerance
        verify_webhook(raw_body, request.headers, secret, tolerance=120)

    The v1 signature covers ``timestamp + "." + raw_body``; the timestamp must be within ``tolerance``
    seconds of now. A delivery without X-Callio-Timestamp is rejected unless ``allow_legacy=True`` (then
    the body-only X-NGX-Signature is checked; it has no replay protection). Constant-time; returns False
    (never raises) for missing or malformed headers.

    Deprecated form: ``verify_webhook(raw_body, signature_header, secret)`` with the X-NGX-Signature string
    checks only the legacy body signature. Pass the headers instead."""
    return _reason(raw_body, headers, secret, tolerance, allow_legacy, now) is None


class WebhookEvent(Dict[str, Any]):
    """A verified event: a dict (``event["order"]``) with ``type``, ``tenant_id`` and ``at`` shortcuts.

    Types: order.created | order.assigned | order.closed | order.reopened (``order``, ``by``),
    call.* / chat.* (``callId``, ``from``, ``to``, ``payload``), recording.ready (``recordingId``,
    ``durationSec``, ``retainUntil``; never audio), cc.chat-escalated (``interaction``, ``transcriptUrl``),
    report.snapshot (``kpis``, ``series``). New types may be added; ignore ones you don't handle."""

    @property
    def id(self) -> Optional[str]:
        """Unique per delivery event: store it and drop a repeat (same id) inside the tolerance window."""
        v = self.get("id")
        return None if v is None else str(v)

    @property
    def type(self) -> str:
        return str(self.get("type"))

    @property
    def tenant_id(self) -> Optional[str]:
        return self.get("tenantId")

    @property
    def at(self) -> Optional[str]:
        return self.get("at")

    @property
    def is_order_event(self) -> bool:
        return self.type.startswith("order.")


def parse_webhook(raw_body: Raw, headers: HeadersOrSignature, secret: str, *, tolerance: float = DEFAULT_TOLERANCE,
                  allow_legacy: bool = False, now: Optional[float] = None) -> WebhookEvent:
    """Verify the delivery (same arguments as verify_webhook) and parse the event. Raises
    WebhookVerificationError: status 401 for a bad, stale or missing signature, 400 for a body that is not
    an event. ``event.id`` is unique per delivery: use it to drop repeats."""
    reason = _reason(raw_body, headers, secret, tolerance, allow_legacy, now)
    if reason:
        raise WebhookVerificationError(f"Callio webhook: {reason}", 401)
    try:
        ev = json.loads(_bytes(raw_body).decode("utf-8"))
    except ValueError:
        raise WebhookVerificationError("Callio webhook: the body is not JSON", 400) from None
    if not isinstance(ev, dict) or not isinstance(ev.get("type"), str):
        raise WebhookVerificationError("Callio webhook: no event type", 400)
    return WebhookEvent(ev)
