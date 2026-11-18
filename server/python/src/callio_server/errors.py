"""Typed errors. Every API failure is a CallioError with the HTTP status and the server's
``{"error": "<reason>"}`` message; subclasses let callers branch with ``except``."""
from __future__ import annotations

from typing import Any, Optional


class CallioError(Exception):
    """Base error. ``status`` is the HTTP status, 0 when no response arrived."""

    def __init__(self, message: str, status: int = 0, body: Any = None, request: Optional[str] = None) -> None:
        super().__init__(message)
        self.message = message
        self.status = status
        self.body = body
        #: The request's method and path (never the key), for logs.
        self.request = request

    def __repr__(self) -> str:
        return f"{type(self).__name__}(status={self.status}, message={self.message!r}, request={self.request!r})"


class ValidationError(CallioError):
    """400: invalid input (bad id or username, unknown user, wrong user type, missing reason...)."""


class AuthenticationError(CallioError):
    """401: the API key is missing, wrong or revoked."""


class PermissionDeniedError(CallioError):
    """403: organisation suspended, seat quota reached, user disabled, or the request came from a
    network outside the organisation's API allow-list."""


class NotFoundError(CallioError):
    """404: no such user, order, group or recording (or no transcript yet)."""


class ConflictError(CallioError):
    """409: it already exists (user, order)."""


class GoneError(CallioError):
    """410: the recording was deleted."""


class RateLimitError(CallioError):
    """429: the organisation's request rate is exceeded. ``retry_after`` is seconds, from Retry-After."""

    def __init__(self, message: str, status: int = 429, body: Any = None, request: Optional[str] = None,
                 retry_after: Optional[float] = None) -> None:
        super().__init__(message, status, body, request)
        self.retry_after = retry_after


class ServerError(CallioError):
    """5xx from the platform."""


class APIConnectionError(CallioError):
    """No response: DNS, TLS, connection reset..."""


class APITimeoutError(APIConnectionError):
    """No response within the configured timeout."""


_BY_STATUS = {400: ValidationError, 422: ValidationError, 401: AuthenticationError, 403: PermissionDeniedError,
              404: NotFoundError, 409: ConflictError, 410: GoneError}


def error_for(status: int, message: str, body: Any, request: str, retry_after: Optional[float] = None) -> CallioError:
    if status == 429:
        return RateLimitError(message, status, body, request, retry_after)
    cls = _BY_STATUS.get(status) or (ServerError if status >= 500 else CallioError)
    return cls(message, status, body, request)
