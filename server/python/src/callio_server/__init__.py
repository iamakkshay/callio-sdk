"""Callio server SDK: the tenant REST API and webhook verification, on the standard library."""
from ._version import __version__
from .client import Callio
from .errors import (APIConnectionError, APITimeoutError, AuthenticationError, CallioError, ConflictError, GoneError,
                     NotFoundError, PermissionDeniedError, RateLimitError, ServerError, ValidationError)
from .resources import RecordingAudio
from .webhooks import (DEFAULT_TOLERANCE, SIGNATURE_HEADER, SIGNATURE_V1_HEADER, TIMESTAMP_HEADER, WebhookEvent,
                       WebhookVerificationError, parse_webhook, sign_webhook, sign_webhook_v1, verify_webhook)

__all__ = [
    "__version__", "Callio", "CallioError", "ValidationError", "AuthenticationError", "PermissionDeniedError",
    "NotFoundError", "ConflictError", "GoneError", "RateLimitError", "ServerError", "APIConnectionError",
    "APITimeoutError", "RecordingAudio", "verify_webhook", "parse_webhook", "sign_webhook", "WebhookEvent",
    "WebhookVerificationError", "SIGNATURE_HEADER", "SIGNATURE_V1_HEADER", "TIMESTAMP_HEADER", "DEFAULT_TOLERANCE",
    "sign_webhook_v1",
]
