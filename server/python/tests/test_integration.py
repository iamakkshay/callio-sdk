"""Integration test against a running Callio stack. Signs in to the admin API, creates a temporary API key
for the tenant, exercises the SDK, and cleans up everything it made (users, order, group, the key).
Nothing secret lives here; pass it in the environment:

    CALLIO_ADMIN_PASS=... [CALLIO_ADMIN_USER=admin] [CALLIO_URL=http://localhost:8080] [CALLIO_TENANT=lab] \\
      python3 -m unittest tests.test_integration -v

CALLIO_IT_AUDIO=1 also downloads one recording (that read is written to the recording's access trail).
Skipped when CALLIO_ADMIN_PASS is not set."""
from __future__ import annotations

import io
import json
import os
import sys
import time
import unittest
import urllib.request
from typing import Any, Dict, Optional

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from callio_server import AuthenticationError, Callio, ConflictError, NotFoundError, PermissionDeniedError, ValidationError  # noqa: E402

URL = os.environ.get("CALLIO_URL", "http://localhost:8080").rstrip("/")
TENANT = os.environ.get("CALLIO_TENANT", "lab")
PASS = os.environ.get("CALLIO_ADMIN_PASS")
RUN = format(int(time.time() * 1000), "x")
CUST, AGENT, ORDER, GROUP = f"sdk-it-py-c-{RUN}", f"sdk-it-py-a-{RUN}", f"SDK-IT-PY-{RUN}", f"sdk-it-py-g-{RUN}"


def admin_req(method: str, path: str, body: Any = None, token: Optional[str] = None) -> Dict[str, Any]:
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(URL + path, data=json.dumps(body).encode() if body is not None else None, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as r:  # noqa: S310
        return json.loads(r.read() or b"{}")


@unittest.skipUnless(PASS, "set CALLIO_ADMIN_PASS (and optionally CALLIO_ADMIN_USER, CALLIO_URL, CALLIO_TENANT)")
class IntegrationTest(unittest.TestCase):
    admin: str
    key: Dict[str, Any]
    callio: Callio

    @classmethod
    def setUpClass(cls) -> None:
        cls.admin = admin_req("POST", "/api/admin/login", {"username": os.environ.get("CALLIO_ADMIN_USER", "admin"), "password": PASS})["token"]
        cls.key = admin_req("POST", f"/api/admin/tenants/{TENANT}/api-keys", {"name": f"sdk-it-py-{RUN}"}, cls.admin)["key"]
        cls.callio = Callio(api_key=cls.key["key"], base_url=URL, user_agent="callio-it",
                            allow_insecure=URL.startswith("http://"))
        cls.created_users = []
        cls.group: Optional[str] = None
        cls.order: Optional[str] = None

    @classmethod
    def tearDownClass(cls) -> None:
        c = cls.callio
        try:
            if cls.group:
                _quiet(lambda: c.groups.delete(GROUP))
            if cls.order:
                _quiet(lambda: c.orders.close(ORDER))  # orders can't be deleted; erasing the users pseudonymises it
            for u in list(cls.created_users):
                _quiet(lambda u=u: c.users.delete(u, reason="SDK integration test cleanup"))
        finally:
            admin_req("DELETE", f"/api/admin/tenants/{TENANT}/api-keys/{cls.key['id']}", token=cls.admin)
        try:
            c.users.list(limit=1)
            raise AssertionError("the revoked key still works")
        except AuthenticationError:
            pass

    def test_1_users(self) -> None:
        c = self.callio
        u = c.users.create(CUST, display_name="SDK IT Customer", user_type="customer")
        type(self).created_users.append(CUST)
        self.assertEqual((u["username"], u["userType"]), (CUST, "customer"))
        self.assertTrue(u["extension"])
        self.assertTrue(u.get("initialPassword"))
        with self.assertRaises(ConflictError):
            c.users.create(CUST)
        with self.assertRaises(ValidationError):
            c.users.create("bad name!")
        with self.assertRaises(NotFoundError):
            c.users.get(CUST + "-missing")
        self.assertEqual(c.users.get(CUST)["displayName"], "SDK IT Customer")
        u = c.users.update(CUST, display_name="SDK IT Renamed", segment="sdk-it")
        self.assertEqual((u["displayName"], u["segment"]), ("SDK IT Renamed", "sdk-it"))
        self.assertTrue(any(x["username"] == CUST for x in c.users.list(q=CUST)))
        t = c.tokens.create(CUST, ttl_sec=120)
        self.assertEqual(len(t["token"].split(".")), 3)
        self.assertEqual(t["userType"], "customer")
        self.assertEqual(c.users.sign_out(CUST), {"ok": True})
        self.assertIn("exportedAt", c.users.export(CUST))

    def test_2_for_user(self) -> None:
        c = self.callio
        first = c.tokens.for_user(AGENT, display_name="SDK IT Agent", user_type="agent", ttl_sec=60)
        type(self).created_users.append(AGENT)
        self.assertTrue(first["created"])
        self.assertEqual(first["userType"], "agent")
        again = c.tokens.for_user(AGENT, user_type="agent")
        self.assertFalse(again["created"])
        c.users.disable(AGENT)
        with self.assertRaises(PermissionDeniedError):
            c.tokens.create(AGENT)
        c.users.enable(AGENT)

    def test_3_orders_and_events(self) -> None:
        c = self.callio
        start = c.events.list(after=0, limit=1)["next"]
        with self.assertRaises(ValidationError):
            c.orders.create(ORDER, customer=AGENT)  # wrong user type
        o = c.orders.create(ORDER, customer=CUST, label="SDK integration test")
        type(self).order = ORDER
        self.assertEqual((o["status"], o["agent"]), ("active", None))
        with self.assertRaises(ConflictError):
            c.orders.create(ORDER, customer=CUST)
        self.assertEqual(c.orders.get(ORDER)["label"], "SDK integration test")
        self.assertTrue(any(x["id"] == ORDER for x in c.orders.list(user=CUST)))
        self.assertEqual(c.orders.assign(ORDER, AGENT)["agent"], AGENT)
        self.assertEqual(c.orders.close(ORDER)["status"], "closed")
        self.assertEqual(c.orders.reopen(ORDER)["status"], "active")
        self.assertEqual(c.orders.update(ORDER, status="closed")["status"], "closed")
        with self.assertRaises(NotFoundError):
            c.orders.get(ORDER + "-nope")
        seen = [e["type"] for e in c.events.iterate(after=max(0, start - 1), types=["order."], limit=100) if e["orderId"] == ORDER]
        for t in ("order.created", "order.assigned", "order.closed", "order.reopened"):
            self.assertIn(t, seen)

    def test_4_groups(self) -> None:
        c = self.callio
        g = c.groups.create(GROUP, name="SDK IT group", members=[CUST, AGENT])
        type(self).group = GROUP
        self.assertEqual(len(g["members"]), 2)
        self.assertEqual(c.groups.get(GROUP)["name"], "SDK IT group")
        g = c.groups.update(GROUP, name="SDK IT renamed", remove=[AGENT])
        self.assertEqual([m["username"] for m in g["members"]], [CUST])
        self.assertTrue(any(x["id"] == GROUP for x in c.groups.list()))
        self.assertEqual(c.groups.delete(GROUP), {"ok": True})
        type(self).group = None
        with self.assertRaises(NotFoundError):
            c.groups.get(GROUP)

    def test_5_recordings_and_cdr(self) -> None:
        c = self.callio
        recs = c.recordings.list(limit=5)
        self.assertIsInstance(recs, list)
        if recs:
            self.assertEqual(c.recordings.get(recs[0]["id"])["id"], recs[0]["id"])
            if os.environ.get("CALLIO_IT_AUDIO") == "1":
                buf = io.BytesIO()
                self.assertEqual(c.recordings.download(recs[0]["id"], buf, reason="SDK integration test"), recs[0]["bytes"])
                self.assertEqual(buf.getvalue()[:4], b"OggS")
        with self.assertRaises(NotFoundError):
            c.recordings.get("no-such-recording")
        with self.assertRaises(NotFoundError):
            c.recordings.audio("no-such-recording", reason="SDK integration test")
        cdr = c.cdr.list(days=30)
        self.assertEqual(cdr["days"], 30)
        self.assertIsInstance(cdr["calls"], list)

    def test_6_erasure(self) -> None:
        c = self.callio
        r = c.users.delete(AGENT, reason="SDK integration test cleanup")
        self.assertTrue(r["ok"])
        self.assertTrue(r["alias"].startswith("erased-"))
        type(self).created_users.remove(AGENT)
        with self.assertRaises(NotFoundError):
            c.users.get(AGENT)


def _quiet(fn: Any) -> None:
    try:
        fn()
    except Exception:  # noqa: BLE001
        pass


if __name__ == "__main__":
    unittest.main()
