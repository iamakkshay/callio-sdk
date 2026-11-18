package callio

import (
	"errors"
	"fmt"
	"time"
)

// Sentinel errors for errors.Is. Every failure from the API is an *Error; its kind is one of these.
//
//	if errors.Is(err, callio.ErrConflict) { ... }
//	var ce *callio.Error
//	if errors.As(err, &ce) { log.Println(ce.Status, ce.Request) }
var (
	// ErrValidation: 400, invalid input (bad id or username, unknown user, wrong user type, missing reason…).
	ErrValidation = errors.New("callio: validation error")
	// ErrAuthentication: 401, the API key is missing, wrong or revoked.
	ErrAuthentication = errors.New("callio: authentication error")
	// ErrPermissionDenied: 403, the organisation is suspended, a seat quota is reached, the user is
	// disabled, or the call came from a network outside the organisation's API allow-list.
	ErrPermissionDenied = errors.New("callio: permission denied")
	// ErrNotFound: 404, no such user, order, group or recording (or no transcript yet).
	ErrNotFound = errors.New("callio: not found")
	// ErrConflict: 409, it already exists (user, order).
	ErrConflict = errors.New("callio: conflict")
	// ErrGone: 410, the recording was deleted.
	ErrGone = errors.New("callio: gone")
	// ErrRateLimit: 429, the organisation's request rate is exceeded; see Error.RetryAfter.
	ErrRateLimit = errors.New("callio: rate limited")
	// ErrServer: 5xx from the platform.
	ErrServer = errors.New("callio: server error")
	// ErrConnection: no response (DNS, TLS, connection reset…). Timeouts match it too.
	ErrConnection = errors.New("callio: connection error")
	// ErrTimeout: no response within the configured timeout.
	ErrTimeout = errors.New("callio: timeout")
	// ErrWebhookVerification: a bad or missing webhook signature, or a body that is not a Callio event.
	ErrWebhookVerification = errors.New("callio: webhook verification failed")
	// ErrRedirect: the server answered with a redirect, which the SDK never follows (it would carry the
	// API key to another host). Usually a wrong base URL (http:// instead of https://, or a moved host).
	ErrRedirect = errors.New("callio: redirect refused")
	// ErrInvalidArgument: a required argument is missing or invalid (checked before any request).
	ErrInvalidArgument = errors.New("callio: invalid argument")
)

// Error is every failure the SDK returns from the API. It never contains the API key.
type Error struct {
	// Status is the HTTP status; 0 when no response arrived (network failure or timeout).
	Status int
	// Message is the server's `error` text (or the SDK's own description).
	Message string
	// Body is the parsed response body, when there was one.
	Body any
	// Request is the method and path, e.g. "GET /api/v1/orders/X" (never the key), for logs.
	Request string
	// RetryAfter is the Retry-After header of a 429, when the server sent one.
	RetryAfter *time.Duration

	kind  error
	cause error
}

func (e *Error) Error() string {
	if e.Status == 0 || e.Request == "" {
		return e.Message
	}
	return fmt.Sprintf("callio: %s: %d %s", e.Request, e.Status, e.Message)
}

// Is matches the sentinel for the error's kind (a timeout also matches ErrConnection).
func (e *Error) Is(target error) bool {
	if e.kind == nil {
		return false
	}
	if target == e.kind {
		return true
	}
	return e.kind == ErrTimeout && target == ErrConnection
}

// Unwrap returns the underlying transport error, if any.
func (e *Error) Unwrap() error { return e.cause }

// Kind returns the sentinel this error matches (nil for an unexpected status such as 418).
func (e *Error) Kind() error { return e.kind }

func kindFor(status int) error {
	switch status {
	case 400, 422:
		return ErrValidation
	case 401:
		return ErrAuthentication
	case 403:
		return ErrPermissionDenied
	case 404:
		return ErrNotFound
	case 409:
		return ErrConflict
	case 410:
		return ErrGone
	case 429:
		return ErrRateLimit
	}
	if status >= 500 {
		return ErrServer
	}
	return nil
}

func errorFor(status int, message string, body any, request string, retryAfter *time.Duration) *Error {
	e := &Error{Status: status, Message: message, Body: body, Request: request, kind: kindFor(status)}
	if status == 429 {
		e.RetryAfter = retryAfter
	}
	return e
}

func invalidArg(msg string) error { return fmt.Errorf("%w: %s", ErrInvalidArgument, msg) }
