"""Unit tests with a mocked HTTP layer (HttpClient._open): no network. ``python3 -m unittest discover -s tests``"""
from __future__ import annotations

import hashlib
import hmac
import io
import json
import os
import socket
import sys
import tempfile
import unittest
import urllib.error
from email.message import Message
from typing import Any, Dict, List
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from callio_server import (APIConnectionError, APITimeoutError, AuthenticationError, Callio, CallioError,  # noqa: E402
                           ConflictError, GoneError, NotFoundError, PermissionDeniedError, RateLimitError, ServerError,
                           ValidationError, WebhookVerificationError, __version__, parse_webhook, sign_webhook,
                           sign_webhook_v1, verify_webhook)

KEY = "cio_abc123_s3cret-value"


def _headers(h: Dict[str, str]) -> Message:
    m = Message()
    for k, v in h.items():
        m[k] = v
    return m


class FakeResponse:
    def __init__(self, status: int, body: bytes, headers: Dict[str, str]) -> None:
        self.status = status
        self._buf = io.BytesIO(body)
        self.headers = _headers(headers)
        self.closed = False

    def read(self, n: int = -1) -> bytes:
        return self._buf.read(n)

    def close(self) -> None:
        self.closed = True


def ok(body: Any, status: int = 200, headers: Dict[str, str] = None) -> FakeResponse:
    return FakeResponse(status, json.dumps(body).encode(), {"Content-Type": "application/json", **(headers or {})})


def http_error(status: int, body: Any, headers: Dict[str, str] = None) -> urllib.error.HTTPError:
    return urllib.error.HTTPError("https://x", status, "err", _headers({"Content-Type": "application/json", **(headers or {})}),
                                  io.BytesIO(json.dumps(body).encode()))


class Harness:
    def __init__(self, client: Callio, responses: List[Any]) -> None:
        self.calls: List[Dict[str, Any]] = []
        self.responses = list(responses)
        self.sleeps: List[float] = []
        client.http._open = self._open  # type: ignore[method-assign]
        client.http.sleep = self.sleeps.append  # type: ignore[assignment]

    def _open(self, req: Any, timeout: float) -> Any:
        self.calls.append({"method": req.get_method(), "url": req.full_url, "headers": dict(req.header_items()),
                           "json": json.loads(req.data) if req.data else None, "timeout": timeout})
        r = self.responses.pop(0)
        if isinstance(r, BaseException):
            raise r
        return r


def make(*responses: Any, **kw: Any):
    c = Callio(api_key=KEY, base_url="https://api.example.test/", **kw)
    return c, Harness(c, list(responses))


class ClientTests(unittest.TestCase):
    def test_auth_header_body_user_agent(self) -> None:
        c, h = make(ok({"user": {"username": "u1", "extension": "1001"}}, 201))
        u = c.users.create("u1", display_name="U One", user_type="customer")
        self.assertEqual(u["extension"], "1001")
        call = h.calls[0]
        self.assertEqual(call["url"], "https://api.example.test/api/v1/users")
        self.assertEqual(call["method"], "POST")
        self.assertEqual(call["headers"]["Authorization"], f"Bearer {KEY}")
        self.assertEqual(call["headers"]["Content-type"], "application/json")
        self.assertTrue(call["headers"]["User-agent"].startswith(f"callio-server-python/{__version__} python/"))
        self.assertEqual(call["json"], {"username": "u1", "displayName": "U One", "userType": "customer"})
        self.assertEqual(call["timeout"], 30.0)

    def test_query_and_path_encoding(self) -> None:
        c, h = make(ok({"users": []}), ok({"events": [], "next": 0}), ok({"user": {}}), ok({"recordings": []}))
        c.users.list(q="sa ra", type="agent")
        c.events.list(after=5, types=["call.", "chat."])
        c.users.get("a/b@c")
        c.recordings.list(call_id="X1", min_duration=10, from_="2026-01-01")
        self.assertEqual(h.calls[0]["url"], "https://api.example.test/api/v1/users?q=sa+ra&type=agent")
        self.assertEqual(h.calls[1]["url"], "https://api.example.test/api/v1/events?after=5&types=call.%2Cchat.")
        self.assertEqual(h.calls[2]["url"], "https://api.example.test/api/v1/users/a%2Fb%40c")
        self.assertEqual(parse_qs(urlparse(h.calls[3]["url"]).query), {"from": ["2026-01-01"], "callId": ["X1"], "minDuration": ["10"]})

    def test_status_to_error(self) -> None:
        cases = [(400, ValidationError), (401, AuthenticationError), (403, PermissionDeniedError), (404, NotFoundError),
                 (409, ConflictError), (410, GoneError), (500, ServerError), (418, CallioError)]
        for status, cls in cases:
            c, _ = make(http_error(status, {"error": f"reason {status}"}), max_retries=0)
            with self.assertRaises(cls) as cm:
                c.orders.get("X")
            e = cm.exception
            self.assertIsInstance(e, CallioError)
            self.assertEqual((e.status, e.message, e.request), (status, f"reason {status}", "GET /api/v1/orders/X"))
            self.assertNotIn(KEY, repr(e) + str(e))

    def test_ip_allowlist_is_permission_denied(self) -> None:
        c, _ = make(http_error(403, {"error": "this network (203.0.113.9) is not allowed to use this organisation's API"}))
        with self.assertRaisesRegex(PermissionDeniedError, "not allowed"):
            c.users.list()

    def test_get_retries_429_and_5xx(self) -> None:
        c, h = make(http_error(429, {"error": "slow"}, {"Retry-After": "2"}), http_error(503, {"error": "busy"}), ok({"orders": [{"id": "A"}]}))
        self.assertEqual(c.orders.list()[0]["id"], "A")
        self.assertEqual(len(h.calls), 3)
        self.assertEqual(h.sleeps[0], 2.0)
        self.assertLessEqual(h.sleeps[1], 1.0)

    def test_rate_limit_error_after_retries(self) -> None:
        c, h = make(http_error(429, {"error": "a"}, {"Retry-After": "7"}), http_error(429, {"error": "b"}, {"Retry-After": "7"}), max_retries=1)
        with self.assertRaises(RateLimitError) as cm:
            c.cdr.list()
        self.assertEqual(cm.exception.retry_after, 7.0)
        self.assertEqual(len(h.calls), 2)

    def test_post_patch_not_retried(self) -> None:
        c, h = make(http_error(503, {"error": "busy"}))
        with self.assertRaises(ServerError):
            c.orders.create("O1", customer="c")
        self.assertEqual(len(h.calls), 1)
        c, h = make(http_error(429, {"error": "slow"}, {"Retry-After": "1"}))
        with self.assertRaises(RateLimitError):
            c.orders.close("O1")
        self.assertEqual(len(h.calls), 1)

    def test_network_error_and_timeout(self) -> None:
        err = urllib.error.URLError(ConnectionRefusedError("refused"))
        c, h = make(err, err, err)
        with self.assertRaises(APIConnectionError) as cm:
            c.groups.list()
        self.assertEqual(cm.exception.status, 0)
        self.assertEqual(len(h.calls), 3)
        c, h = make(socket.timeout("timed out"), max_retries=0, timeout=0.5)
        with self.assertRaises(APITimeoutError):
            c.users.get("x")
        self.assertEqual(h.calls[0]["timeout"], 0.5)

    def test_for_user_creates_then_token(self) -> None:
        c, h = make(ok({"user": {"username": "c1"}}, 201), ok({"token": "jwt", "userType": "customer", "expiresAt": "later"}))
        t = c.tokens.for_user("c1", display_name="C", user_type="customer", ttl_sec=600)
        self.assertEqual(t, {"token": "jwt", "userType": "customer", "expiresAt": "later", "created": True})
        self.assertEqual(h.calls[0]["json"], {"username": "c1", "displayName": "C", "userType": "customer"})
        self.assertEqual(h.calls[1]["json"], {"username": "c1", "ttlSec": 600})

    def test_for_user_409_means_exists(self) -> None:
        c, _ = make(http_error(409, {"error": "user exists"}), ok({"token": "jwt", "userType": "agent", "expiresAt": "x"}))
        t = c.tokens.for_user("a1", user_type="agent")
        self.assertFalse(t["created"])
        self.assertEqual(t["token"], "jwt")

    def test_for_user_propagates_quota(self) -> None:
        c, h = make(http_error(403, {"error": "seat quota reached"}))
        with self.assertRaises(PermissionDeniedError):
            c.tokens.for_user("a1")
        self.assertEqual(len(h.calls), 1)

    def test_partial_updates_send_only_given_fields(self) -> None:
        o = {"order": {"id": "O1"}}
        c, h = make(ok(o), ok(o), ok(o), ok({"user": {}}))
        c.orders.assign("O1", "drv")
        c.orders.assign("O1", None)
        c.orders.reopen("O1")
        c.users.update("u", segment=None, display_name="N")
        self.assertEqual([x["json"] for x in h.calls], [{"agent": "drv"}, {"agent": None}, {"status": "active"}, {"displayName": "N", "segment": None}])

    def test_delete_user_reason_in_body(self) -> None:
        c, h = make(ok({"ok": True, "alias": "erased-1", "removed": {}, "recordingsKeptOnLegalHold": []}))
        self.assertEqual(c.users.delete("u1", reason="customer asked")["alias"], "erased-1")
        self.assertEqual((h.calls[0]["method"], h.calls[0]["json"]), ("DELETE", {"reason": "customer asked"}))

    def test_audio_stream_and_download(self) -> None:
        data = b"OggS" + bytes(range(200)) * 1000
        audio = lambda: FakeResponse(200, data, {"Content-Type": "audio/ogg", "Content-Length": str(len(data))})  # noqa: E731
        c, h = make(audio(), audio(), audio())
        with c.recordings.audio("rec-1", reason="QA review — طلب") as a:
            self.assertEqual((a.content_type, a.content_length), ("audio/ogg", len(data)))
            self.assertEqual(b"".join(a.iter_bytes(4096)), data)
        self.assertEqual(parse_qs(urlparse(h.calls[0]["url"]).query)["reason"], ["QA review — طلب"])
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "a.ogg")
            self.assertEqual(c.recordings.download("rec-1", p, reason="dispute 123"), len(data))
            with open(p, "rb") as f:
                self.assertEqual(f.read(), data)
        buf = io.BytesIO()
        self.assertEqual(c.recordings.download("rec-1", buf, reason="dispute 123"), len(data))

    def test_audio_reason_required_and_410(self) -> None:
        c, _ = make(http_error(410, {"error": "this recording was deleted"}))
        with self.assertRaises(ValueError):
            c.recordings.audio("r", reason="no")
        with self.assertRaises(GoneError):
            c.recordings.audio("r", reason="audit check")

    def test_events_iterate(self) -> None:
        c, h = make(ok({"events": [{"id": 1}, {"id": 2}], "next": 2}), ok({"events": [{"id": 3}], "next": 3}), ok({"events": [], "next": 3}))
        self.assertEqual([e["id"] for e in c.events.iterate(limit=2)], [1, 2, 3])
        self.assertEqual([parse_qs(urlparse(x["url"]).query)["after"] for x in h.calls], [["0"], ["2"], ["3"]])

    def test_key_not_in_repr(self) -> None:
        c, _ = make()
        self.assertNotIn(KEY, repr(c) + repr(c.http) + str(c.__dict__))

    def test_constructor_validation_and_env(self) -> None:
        saved = dict(os.environ)
        try:
            os.environ.pop("CALLIO_API_KEY", None)
            os.environ.pop("CALLIO_BASE_URL", None)
            with self.assertRaisesRegex(CallioError, "api_key is required"):
                Callio(base_url="https://x")
            with self.assertRaisesRegex(CallioError, "base_url is required"):
                Callio(api_key=KEY)
            with self.assertRaisesRegex(CallioError, "https"):
                Callio(api_key=KEY, base_url="api.example.sa")
            os.environ.update(CALLIO_API_KEY=KEY, CALLIO_BASE_URL="https://env.example/")
            self.assertEqual(Callio().http.base_url, "https://env.example")
        finally:
            os.environ.clear()
            os.environ.update(saved)


SECRET = "whsec_test"
BODY = json.dumps({"tenantId": "lab", "type": "order.assigned", "order": {"id": "O1", "agent": "drv"}, "by": "apikey:abc", "at": "2026-01-01T00:00:00Z"})
SIG = "sha256=" + hmac.new(SECRET.encode(), BODY.encode(), hashlib.sha256).hexdigest()


class WebhookTests(unittest.TestCase):
    def test_verify_accepts(self) -> None:
        self.assertEqual(sign_webhook(BODY, SECRET), SIG)
        self.assertTrue(verify_webhook(BODY, SIG, SECRET))
        self.assertTrue(verify_webhook(BODY.encode(), SIG, SECRET))
        self.assertTrue(verify_webhook(bytearray(BODY.encode()), "sha256=" + SIG[7:].upper(), SECRET))
        self.assertTrue(verify_webhook(BODY, [SIG], SECRET))

    def test_verify_rejects(self) -> None:
        self.assertFalse(verify_webhook(BODY + " ", SIG, SECRET))
        self.assertFalse(verify_webhook(BODY, SIG, "other"))
        for h in (None, "", "sha256=", "sha256=zz", SIG[7:], "sha1=" + SIG[7:], SIG + "00", []):
            self.assertFalse(verify_webhook(BODY, h, SECRET), h)
        with self.assertRaises(ValueError):
            verify_webhook(BODY, SIG, "")

    def test_parse(self) -> None:
        ev = parse_webhook(BODY, SIG, SECRET)
        self.assertTrue(ev.is_order_event)
        self.assertEqual((ev.type, ev.tenant_id, ev["order"]["agent"]), ("order.assigned", "lab", "drv"))
        with self.assertRaises(WebhookVerificationError):
            parse_webhook(BODY, "sha256=" + "0" * 64, SECRET)
        with self.assertRaises(WebhookVerificationError):
            parse_webhook("nope", sign_webhook("nope", SECRET), SECRET)


NOW = 1_800_000_000
V1_BODY = json.dumps({"id": "evt_123", "tenantId": "lab", "type": "order.created", "order": {"id": "O2"}, "by": "admin:a",
                      "at": "2026-01-01T00:00:00Z"})


def v1_headers(ts: int = NOW, body: str = V1_BODY, secret: str = SECRET) -> Dict[str, str]:
    return {"X-Callio-Timestamp": str(ts), "X-Callio-Signature": sign_webhook_v1(body, secret, ts),
            "X-NGX-Signature": sign_webhook(body, secret)}


class WebhookV1Tests(unittest.TestCase):
    def test_v1_accepts_and_exposes_id(self) -> None:
        want = "v1=" + hmac.new(SECRET.encode(), f"{NOW}.{V1_BODY}".encode(), hashlib.sha256).hexdigest()
        self.assertEqual(sign_webhook_v1(V1_BODY, SECRET, NOW), want)
        self.assertTrue(verify_webhook(V1_BODY, v1_headers(), SECRET, now=NOW))
        self.assertTrue(verify_webhook(V1_BODY.encode(), v1_headers(), SECRET, now=NOW + 300))
        lower = {k.lower(): v for k, v in v1_headers().items()}
        self.assertTrue(verify_webhook(V1_BODY, lower, SECRET, now=NOW))
        # e.g. Flask/werkzeug-style or email.message headers: .get + .items, case-insensitive
        m = Message()
        m["x-CALLIO-timestamp"] = str(NOW)
        m["X-Callio-Signature"] = "v1=" + "0" * 64 + ", " + want
        self.assertTrue(verify_webhook(V1_BODY, m, SECRET, now=NOW))
        ev = parse_webhook(V1_BODY, v1_headers(), SECRET, now=NOW)
        self.assertEqual((ev.id, ev.type), ("evt_123", "order.created"))

    def test_v1_rejects_stale_tampered_and_missing_timestamp(self) -> None:
        self.assertFalse(verify_webhook(V1_BODY, v1_headers(NOW - 301), SECRET, now=NOW))
        self.assertFalse(verify_webhook(V1_BODY, v1_headers(NOW + 301), SECRET, now=NOW))
        self.assertTrue(verify_webhook(V1_BODY, v1_headers(NOW - 500), SECRET, now=NOW, tolerance=600))
        self.assertFalse(verify_webhook(V1_BODY, v1_headers(NOW - 61), SECRET, now=NOW, tolerance=60))
        self.assertFalse(verify_webhook(V1_BODY + " ", v1_headers(), SECRET, now=NOW))
        self.assertFalse(verify_webhook(V1_BODY, v1_headers(secret="other"), SECRET, now=NOW))
        replay = {**v1_headers(NOW - 1000), "X-Callio-Timestamp": str(NOW)}
        self.assertFalse(verify_webhook(V1_BODY, replay, SECRET, now=NOW))
        for ts in ("abc", "1e9", "-5", "1.5"):
            self.assertFalse(verify_webhook(V1_BODY, {**v1_headers(), "X-Callio-Timestamp": ts}, SECRET, now=NOW), ts)
        legacy_only = {"X-NGX-Signature": sign_webhook(V1_BODY, SECRET)}
        self.assertFalse(verify_webhook(V1_BODY, legacy_only, SECRET))
        with self.assertRaisesRegex(WebhookVerificationError, "X-Callio-Timestamp"):
            parse_webhook(V1_BODY, legacy_only, SECRET)
        self.assertTrue(verify_webhook(V1_BODY, legacy_only, SECRET, allow_legacy=True))
        self.assertEqual(parse_webhook(V1_BODY, legacy_only, SECRET, allow_legacy=True).id, "evt_123")
        self.assertFalse(verify_webhook(V1_BODY, {"X-NGX-Signature": SIG}, SECRET, allow_legacy=True))
        both = {**legacy_only, "X-Callio-Timestamp": str(NOW)}
        self.assertFalse(verify_webhook(V1_BODY, both, SECRET, now=NOW, allow_legacy=True))
        with self.assertRaises(WebhookVerificationError) as cm:
            parse_webhook(V1_BODY, v1_headers(NOW - 301), SECRET, now=NOW)
        self.assertEqual(cm.exception.status, 401)
        self.assertIn("tolerance", str(cm.exception))


class HardeningTests(unittest.TestCase):
    def test_redirects_are_refused_and_never_carry_the_key(self) -> None:
        import http.server
        import threading
        seen: Dict[str, Any] = {}

        class B(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                seen["auth"] = self.headers.get("Authorization")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"users":[]}')

            def log_message(self, *a: Any) -> None:
                pass

        sb = http.server.HTTPServer(("127.0.0.1", 0), B)

        class A(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                self.send_response(302)
                self.send_header("Location", "http://localhost:%d/x" % sb.server_address[1])
                self.end_headers()

            def log_message(self, *a: Any) -> None:
                pass

        sa = http.server.HTTPServer(("127.0.0.1", 0), A)
        for srv in (sa, sb):
            threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            c = Callio(api_key=KEY, base_url="http://127.0.0.1:%d" % sa.server_address[1], allow_insecure=True,
                       max_retries=0)
            with self.assertRaisesRegex(CallioError, "redirect") as cm:
                c.users.list()
            self.assertEqual(cm.exception.status, 302)
            self.assertNotIn(KEY, str(cm.exception))
            self.assertNotIn("auth", seen)
        finally:
            sa.shutdown()
            sb.shutdown()

    def test_https_required_unless_allow_insecure(self) -> None:
        with self.assertRaisesRegex(CallioError, "allow_insecure"):
            Callio(api_key=KEY, base_url="http://api.example.sa")
        with self.assertRaisesRegex(CallioError, "https"):
            Callio(api_key=KEY, base_url="ftp://api.example.sa", allow_insecure=True)
        self.assertEqual(Callio(api_key=KEY, base_url="http://localhost:8080/", allow_insecure=True).http.base_url,
                         "http://localhost:8080")

    def test_dot_segments_rejected(self) -> None:
        c, h = make()
        for s in (".", ".."):
            with self.assertRaises(ValidationError):
                c.users.get(s)
            with self.assertRaises(ValidationError):
                c.orders.get(s)
        with self.assertRaises(TypeError):
            c.users.get("")
        self.assertEqual(h.calls, [])


if __name__ == "__main__":
    unittest.main()
