"""The HTTP layer on the standard library (urllib): a timeout per attempt and retries with exponential
backoff for idempotent requests (GET, HEAD, PUT, DELETE) on 429, 5xx and network errors. The API key only
goes into the Authorization header; it is never in an error, a repr or a URL."""
from __future__ import annotations

import email.utils
import json
import os
import platform
import random
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime
from typing import Any, Callable, Dict, Mapping, Optional

from ._version import __version__
from .errors import APIConnectionError, APITimeoutError, CallioError, error_for

IDEMPOTENT = frozenset({"GET", "HEAD", "PUT", "DELETE", "OPTIONS"})


def encode_query(query: Optional[Mapping[str, Any]]) -> str:
    if not query:
        return ""
    pairs = []
    for k, v in query.items():
        if v is None or v == "":
            continue
        if isinstance(v, (list, tuple)):
            if not v:
                continue
            v = ",".join(str(x) for x in v)
        elif isinstance(v, bool):
            v = "true" if v else "false"
        elif isinstance(v, datetime):
            v = v.isoformat()
        elif isinstance(v, date):
            v = v.isoformat()
        pairs.append((k, str(v)))
    return ("?" + urllib.parse.urlencode(pairs)) if pairs else ""


def parse_retry_after(value: Optional[str]) -> Optional[float]:
    if not value:
        return None
    try:
        n = float(value)
        return n if n >= 0 else None
    except ValueError:
        pass
    try:
        dt = email.utils.parsedate_to_datetime(value)
        return max(0.0, dt.timestamp() - time.time())
    except (TypeError, ValueError):
        return None


class _RefuseRedirects(urllib.request.HTTPRedirectHandler):
    """urllib's default handler follows redirects and re-sends every header, Authorization included, to
    wherever the Location points. Refuse instead: returning None surfaces the 3xx as an HTTPError."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        return None


class HttpClient:
    def __init__(self, api_key: Optional[str] = None, base_url: Optional[str] = None, *, timeout: float = 30.0,
                 max_retries: int = 2, user_agent: Optional[str] = None, allow_insecure: bool = False) -> None:
        api_key = api_key or os.environ.get("CALLIO_API_KEY")
        base_url = base_url or os.environ.get("CALLIO_BASE_URL")
        if not api_key:
            raise CallioError("Callio: api_key is required (or set CALLIO_API_KEY)")
        if not base_url:
            raise CallioError("Callio: base_url is required (or set CALLIO_BASE_URL), e.g. https://api.example.sa")
        scheme = urllib.parse.urlsplit(base_url).scheme.lower()
        if scheme == "http":
            if not allow_insecure:
                raise CallioError("Callio: base_url must use https://; http:// is allowed only for development "
                                  "with allow_insecure=True")
        elif scheme != "https" or not urllib.parse.urlsplit(base_url).netloc:
            raise CallioError("Callio: base_url must be an https:// URL, e.g. https://api.example.sa")
        self.__api_key = api_key
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.max_retries = max(0, int(max_retries))
        self.user_agent = f"callio-server-python/{__version__} python/{platform.python_version()}" + (f" {user_agent}" if user_agent else "")
        #: Overridable for tests.
        self.sleep: Callable[[float], None] = time.sleep
        self._opener = urllib.request.build_opener(_RefuseRedirects())

    def __repr__(self) -> str:
        return f"HttpClient(base_url={self.base_url!r}, timeout={self.timeout}, max_retries={self.max_retries})"

    def backoff(self, attempt: int, retry_after: Optional[float]) -> float:
        if retry_after is not None:
            return min(retry_after, 60.0)
        return float(min(8.0, 0.5 * 2 ** attempt) * (0.5 + random.random() / 2))

    def _open(self, req: urllib.request.Request, timeout: float) -> Any:
        """The one place a request leaves the process (tests replace it)."""
        return self._opener.open(req, timeout=timeout)  # noqa: S310 (scheme checked in __init__)

    def request(self, method: str, path: str, *, query: Optional[Mapping[str, Any]] = None, body: Any = None,
                stream: bool = False) -> Any:
        """JSON result, or (``stream=True``) the open response object, which the caller must close."""
        url = f"{self.base_url}{path}{encode_query(query)}"
        label = f"{method} {path}"
        headers: Dict[str, str] = {
            "Authorization": f"Bearer {self.__api_key}",
            "Accept": "*/*" if stream else "application/json",
            "User-Agent": self.user_agent,
        }
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        retryable = method in IDEMPOTENT

        attempt = 0
        while True:
            req = urllib.request.Request(url, data=data, headers=headers, method=method)
            try:
                resp = self._open(req, self.timeout)
            except urllib.error.HTTPError as e:
                status = e.code
                if 300 <= status < 400:
                    e.close()
                    raise CallioError(f"Callio: the server answered with a redirect (HTTP {status}) for {label}; redirects "
                                      "are not followed so the API key is never sent elsewhere. Set base_url to the "
                                      "final https:// address.", status, None, label) from None
                try:
                    raw = e.read()
                except Exception:  # noqa: BLE001
                    raw = b""
                finally:
                    e.close()
                retry_after = parse_retry_after(e.headers.get("Retry-After") if e.headers else None)
                if retryable and (status == 429 or status >= 500) and attempt < self.max_retries:
                    self.sleep(self.backoff(attempt, retry_after))
                    attempt += 1
                    continue
                parsed = _parse(raw)
                if isinstance(parsed, dict) and isinstance(parsed.get("error"), str):
                    msg = parsed["error"]
                elif isinstance(parsed, str) and parsed:
                    msg = parsed[:200]
                else:
                    msg = f"HTTP {status}"
                raise error_for(status, msg, parsed, label, retry_after) from None
            except (urllib.error.URLError, socket.timeout, TimeoutError, ConnectionError, OSError) as e:
                reason = getattr(e, "reason", e)
                timed_out = isinstance(reason, (socket.timeout, TimeoutError)) or isinstance(e, (socket.timeout, TimeoutError))
                err: CallioError = (APITimeoutError(f"Callio: no response within {self.timeout} s ({label})", 0, None, label)
                                    if timed_out else
                                    APIConnectionError(f"Callio: could not reach {self.base_url} ({label}): {reason}", 0, None, label))
                if retryable and attempt < self.max_retries:
                    self.sleep(self.backoff(attempt, None))
                    attempt += 1
                    continue
                raise err from None

            if stream:
                return resp
            try:
                raw = resp.read()
            except (socket.timeout, TimeoutError, OSError) as e:
                raise APIConnectionError(f"Callio: the response was cut off ({label}): {e}", 0, None, label) from None
            finally:
                resp.close()
            return _parse(raw)


def _parse(raw: bytes) -> Any:
    if not raw:
        return None
    text = raw.decode("utf-8", errors="replace")
    try:
        return json.loads(text)
    except ValueError:
        return text
