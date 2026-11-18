package callio

// Webhook verification. Callio POSTs JSON events to the organisation's webhook URL and signs them with
// the webhook secret:
//
//	X-Callio-Timestamp: <unix seconds>
//	X-Callio-Signature: v1=<hex HMAC-SHA256(secret, timestamp + "." + rawBody)>
//	X-NGX-Signature:    sha256=<hex HMAC-SHA256(secret, rawBody)>   (legacy, no replay protection)
//
// VerifyWebhookRequest / ParseWebhookRequest check the v1 signature and that the timestamp is within a
// tolerance (default 5 minutes), so a captured request cannot be replayed later. Verify against the
// exact bytes received: re-serialising parsed JSON changes them. Each event carries a unique ID; drop
// ones you have already handled.

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	// SignatureHeader is the legacy body-only signature header.
	SignatureHeader = "X-NGX-Signature"
	// TimestampHeader carries the signing time (unix seconds).
	TimestampHeader = "X-Callio-Timestamp"
	// SignatureV1Header carries the timestamped signature, v1=<hex>.
	SignatureV1Header = "X-Callio-Signature"
	// DefaultWebhookTolerance is how far the timestamp may be from now.
	DefaultWebhookTolerance = 300 * time.Second
)

var (
	sigRE   = regexp.MustCompile(`^sha256=([0-9a-fA-F]{64})$`)
	sigV1RE = regexp.MustCompile(`^v1=([0-9a-fA-F]{64})$`)
)

// WebhookOptions tunes VerifyWebhookRequest and ParseWebhookRequest.
type WebhookOptions struct {
	// Tolerance is the allowed distance between the timestamp and now (default 300 s when 0).
	Tolerance time.Duration
	// AllowLegacy accepts a request without X-Callio-Timestamp by checking the legacy X-NGX-Signature
	// (body only: such a request could be a replay). Off by default.
	AllowLegacy bool
	// Now replaces the clock (tests).
	Now func() time.Time
}

func mac(parts ...[]byte) func(secret string) []byte {
	return func(secret string) []byte {
		m := hmac.New(sha256.New, []byte(secret))
		for _, p := range parts {
			m.Write(p)
		}
		return m.Sum(nil)
	}
}

// SignWebhook returns the legacy `sha256=<hex>` value for this body.
func SignWebhook(rawBody []byte, secret string) string {
	return "sha256=" + hex.EncodeToString(mac(rawBody)(secret))
}

// SignWebhookV1 returns the `v1=<hex>` value Callio sends in X-Callio-Signature for this body and
// timestamp (unix seconds).
func SignWebhookV1(rawBody []byte, timestamp int64, secret string) string {
	return "v1=" + hex.EncodeToString(mac([]byte(strconv.FormatInt(timestamp, 10)+"."), rawBody)(secret))
}

func hexMatch(re *regexp.Regexp, header string, want []byte) bool {
	// Several signatures may be sent (comma separated), e.g. during a secret rotation.
	ok := false
	for _, part := range strings.Split(header, ",") {
		m := re.FindStringSubmatch(strings.TrimSpace(part))
		if m == nil {
			continue
		}
		got, err := hex.DecodeString(strings.ToLower(m[1]))
		if err == nil && hmac.Equal(got, want) {
			ok = true
		}
	}
	return ok
}

// VerifyWebhook is the legacy check: signatureHeader (X-NGX-Signature) is the HMAC-SHA256 of rawBody.
// Constant-time; false for a missing or malformed header; panics when secret is empty.
//
// Deprecated: it cannot detect a replayed request. Use VerifyWebhookRequest with the request headers.
func VerifyWebhook(rawBody []byte, signatureHeader, secret string) bool {
	if secret == "" {
		panic("callio: the webhook secret is required")
	}
	return hexMatch(sigRE, signatureHeader, mac(rawBody)(secret))
}

func whErr(status int, msg string) *Error {
	return &Error{Status: status, Message: "callio webhook: " + msg, kind: ErrWebhookVerification}
}

// VerifyWebhookRequest checks a webhook request's headers against rawBody. It returns nil when
// X-Callio-Signature is valid for X-Callio-Timestamp + "." + rawBody and the timestamp is within the
// tolerance; otherwise an *Error matching ErrWebhookVerification (Status 401). A request without a
// timestamp is rejected unless opts.AllowLegacy is set (then X-NGX-Signature is checked instead).
func VerifyWebhookRequest(rawBody []byte, headers http.Header, secret string, opts *WebhookOptions) error {
	if secret == "" {
		return invalidArg("the webhook secret is required")
	}
	o := WebhookOptions{}
	if opts != nil {
		o = *opts
	}
	if o.Tolerance <= 0 {
		o.Tolerance = DefaultWebhookTolerance
	}
	now := time.Now
	if o.Now != nil {
		now = o.Now
	}
	ts := strings.TrimSpace(headers.Get(TimestampHeader))
	if ts == "" {
		if !o.AllowLegacy {
			return whErr(401, "missing "+TimestampHeader+" (set AllowLegacy to accept body-only signatures)")
		}
		if !VerifyWebhook(rawBody, headers.Get(SignatureHeader), secret) {
			return whErr(401, "bad or missing "+SignatureHeader)
		}
		return nil
	}
	t, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return whErr(401, "malformed "+TimestampHeader)
	}
	// Check the signature first, so a forged timestamp gets the same answer as a forged body.
	want := mac([]byte(ts+"."), rawBody)(secret)
	if !hexMatch(sigV1RE, headers.Get(SignatureV1Header), want) {
		return whErr(401, "bad or missing "+SignatureV1Header)
	}
	d := now().Sub(time.Unix(t, 0))
	if d < 0 {
		d = -d
	}
	if d > o.Tolerance {
		return whErr(401, fmt.Sprintf("timestamp outside the %s tolerance (replayed or clock skew)", o.Tolerance))
	}
	return nil
}

// WebhookEvent is a verified webhook event. Type is always set; the other fields depend on it:
//   - order.created | order.assigned | order.closed | order.reopened: Order, By ("apikey:<id>" or "admin:<username>");
//   - call.* / chat.* / location.*: CallID, From, To, Payload;
//   - recording.ready: CallID, RecordingID, DurationSec, RetainUntil (never audio);
//   - cc.chat-escalated: Interaction, User, EntryPoint, TranscriptURL;
//   - report.snapshot: WindowDays, KPIs, Series, GeneratedAt.
//
// New types may be added; ignore ones you don't handle. Raw holds the whole body.
// ID is the event's unique id (a JSON string or number in the body, as text).
type WebhookEvent struct {
	// ID is unique per event: use it to drop duplicates (store the ids you have handled).
	ID       string `json:"-"`
	Type     string `json:"type"`
	TenantID string `json:"tenantId"`
	At       string `json:"at"`

	Order *Order `json:"order,omitempty"`
	By    string `json:"by,omitempty"`

	CallID  *string        `json:"callId,omitempty"`
	From    *string        `json:"from,omitempty"`
	To      *string        `json:"to,omitempty"`
	Payload map[string]any `json:"payload,omitempty"`

	RecordingID string  `json:"recordingId,omitempty"`
	DurationSec float64 `json:"durationSec,omitempty"`
	RetainUntil *string `json:"retainUntil,omitempty"`

	Interaction   string          `json:"interaction,omitempty"`
	User          string          `json:"user,omitempty"`
	EntryPoint    string          `json:"entryPoint,omitempty"`
	TranscriptURL string          `json:"transcriptUrl,omitempty"`
	Location      json.RawMessage `json:"location,omitempty"`

	WindowDays  int             `json:"windowDays,omitempty"`
	KPIs        map[string]any  `json:"kpis,omitempty"`
	Series      json.RawMessage `json:"series,omitempty"`
	GeneratedAt string          `json:"generatedAt,omitempty"`

	Raw json.RawMessage `json:"-"`
}

// IsOrderEvent reports an order.* event.
func (e *WebhookEvent) IsOrderEvent() bool { return strings.HasPrefix(e.Type, "order.") }

// IsRecordingReady reports a recording.ready event.
func (e *WebhookEvent) IsRecordingReady() bool { return e.Type == "recording.ready" }

// ParseWebhookRequest verifies the request (see VerifyWebhookRequest) and parses the event. The error
// matches ErrWebhookVerification (Status 401 for a bad signature or timestamp, 400 for a body that is
// not an event).
func ParseWebhookRequest(rawBody []byte, headers http.Header, secret string, opts *WebhookOptions) (*WebhookEvent, error) {
	if err := VerifyWebhookRequest(rawBody, headers, secret, opts); err != nil {
		return nil, err
	}
	return decodeEvent(rawBody)
}

// ParseWebhook verifies the legacy X-NGX-Signature and parses the event.
//
// Deprecated: it cannot detect a replayed request. Use ParseWebhookRequest with the request headers.
func ParseWebhook(rawBody []byte, signatureHeader, secret string) (*WebhookEvent, error) {
	if secret == "" {
		return nil, invalidArg("the webhook secret is required")
	}
	if !VerifyWebhook(rawBody, signatureHeader, secret) {
		return nil, whErr(401, "bad or missing "+SignatureHeader)
	}
	return decodeEvent(rawBody)
}

func decodeEvent(rawBody []byte) (*WebhookEvent, error) {
	var probe map[string]json.RawMessage
	if err := json.Unmarshal(rawBody, &probe); err != nil {
		e := whErr(400, "the body is not JSON")
		e.cause = err
		return nil, e
	}
	var t string
	if err := json.Unmarshal(probe["type"], &t); err != nil || t == "" {
		return nil, whErr(400, "no event type")
	}
	var ev WebhookEvent
	if err := json.Unmarshal(rawBody, &ev); err != nil {
		// A field changed shape: keep the event (it is verified) with its common fields and Raw.
		ev = WebhookEvent{Type: t}
		_ = json.Unmarshal(probe["tenantId"], &ev.TenantID)
		_ = json.Unmarshal(probe["at"], &ev.At)
	}
	if raw, ok := probe["id"]; ok {
		var sid string
		if json.Unmarshal(raw, &sid) == nil {
			ev.ID = sid
		} else if string(raw) != "null" {
			ev.ID = string(raw)
		}
	}
	ev.Raw = append(json.RawMessage(nil), rawBody...)
	return &ev, nil
}
