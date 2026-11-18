package callio

// The HTTP layer: net/http, a timeout per attempt, and retries with exponential backoff for idempotent
// requests (GET, HEAD, PUT, DELETE, OPTIONS) on 429, 5xx and network errors. The API key only ever goes
// into the Authorization header; it is never part of an error, a message, a URL or a formatted value.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/rand/v2"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// secret holds the API key behind a pointer, so fmt (which prints nested pointers as addresses and
// cannot call methods on unexported fields) never shows it; it also redacts itself when formatted.
type secret struct{ v string }

func (*secret) String() string               { return "[redacted]" }
func (*secret) GoString() string             { return `"[redacted]"` }
func (*secret) Format(f fmt.State, _ rune)   { _, _ = io.WriteString(f, "[redacted]") }
func (*secret) MarshalJSON() ([]byte, error) { return []byte(`"[redacted]"`), nil }

var idempotent = map[string]bool{"GET": true, "HEAD": true, "PUT": true, "DELETE": true, "OPTIONS": true}

// Query is a request's query string. Empty strings and nil are left out; []string is joined with
// commas; time.Time is sent as ISO 8601 UTC. Keys are sent in sorted order.
type Query map[string]any

// RequestOptions are the optional parts of a raw request.
type RequestOptions struct {
	Query Query
	// Body is JSON-encoded (and sent with Content-Type: application/json) when non-nil.
	Body any
}

// HTTPClient sends authenticated requests. Client.HTTP exposes it for endpoints the SDK doesn't wrap yet.
type HTTPClient struct {
	BaseURL    string
	Timeout    time.Duration
	MaxRetries int
	UserAgent  string

	// Backoff returns the wait before retry number attempt+1. Overridable (tests).
	Backoff func(attempt int, retryAfter *time.Duration) time.Duration

	key    *secret
	client *http.Client
}

// String never includes the key.
func (h HTTPClient) String() string {
	return fmt.Sprintf("callio.HTTPClient{BaseURL: %q, Timeout: %s, MaxRetries: %d}", h.BaseURL, h.Timeout, h.MaxRetries)
}

// GoString never includes the key.
func (h HTTPClient) GoString() string { return h.String() }

func defaultBackoff(attempt int, retryAfter *time.Duration) time.Duration {
	if retryAfter != nil {
		return min(*retryAfter, 60*time.Second)
	}
	base := math.Min(8000, 500*math.Pow(2, float64(attempt)))
	return time.Duration(base*(0.5+rand.Float64()/2)) * time.Millisecond
}

// EncodeQuery builds "?k=v&…" (or "" when nothing is set).
func EncodeQuery(q Query) string {
	if len(q) == 0 {
		return ""
	}
	keys := make([]string, 0, len(q))
	for k := range q {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		s, ok := queryValue(q[k])
		if !ok {
			continue
		}
		if b.Len() == 0 {
			b.WriteByte('?')
		} else {
			b.WriteByte('&')
		}
		b.WriteString(url.QueryEscape(k))
		b.WriteByte('=')
		b.WriteString(url.QueryEscape(s))
	}
	return b.String()
}

func queryValue(v any) (string, bool) {
	switch x := v.(type) {
	case nil:
		return "", false
	case string:
		return x, x != ""
	case []string:
		return strings.Join(x, ","), len(x) > 0
	case time.Time:
		if x.IsZero() {
			return "", false
		}
		return x.UTC().Format("2006-01-02T15:04:05.000Z"), true
	case *time.Time:
		if x == nil || x.IsZero() {
			return "", false
		}
		return x.UTC().Format("2006-01-02T15:04:05.000Z"), true
	case bool:
		return strconv.FormatBool(x), true
	case int:
		return strconv.Itoa(x), true
	case int64:
		return strconv.FormatInt(x, 10), true
	case float64:
		return strconv.FormatFloat(x, 'f', -1, 64), true
	case fmt.Stringer:
		s := x.String()
		return s, s != ""
	default:
		s := fmt.Sprint(x)
		return s, s != ""
	}
}

// ParseRetryAfter reads a Retry-After header (seconds or an HTTP date).
func ParseRetryAfter(h string) *time.Duration {
	h = strings.TrimSpace(h)
	if h == "" {
		return nil
	}
	if n, err := strconv.ParseFloat(h, 64); err == nil {
		if n < 0 || math.IsInf(n, 0) || math.IsNaN(n) {
			return nil
		}
		d := time.Duration(n * float64(time.Second))
		return &d
	}
	if t, err := http.ParseTime(h); err == nil {
		d := time.Until(t)
		if d < 0 {
			d = 0
		}
		d = time.Duration(math.Ceil(d.Seconds())) * time.Second
		return &d
	}
	return nil
}

// cancelOnClose ends a streamed request's context when the body is closed.
type cancelOnClose struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (c *cancelOnClose) Close() error {
	err := c.ReadCloser.Close()
	c.cancel()
	return err
}

// Request sends a request and decodes the JSON response into out (which may be nil).
func (h *HTTPClient) Request(ctx context.Context, method, path string, opts *RequestOptions, out any) error {
	resp, body, err := h.do(ctx, method, path, opts, false)
	if err != nil {
		return err
	}
	if out == nil || len(bytes.TrimSpace(body)) == 0 {
		return nil
	}
	if err := json.Unmarshal(body, out); err != nil {
		return &Error{Status: resp.StatusCode, Message: "callio: could not decode the response: " + err.Error(), Body: string(body), Request: method + " " + path, cause: err}
	}
	return nil
}

// RequestRaw sends a request and returns the open response on a 2xx (for streaming). The caller must
// close resp.Body. The timeout covers getting the response headers; reading the body is not limited.
func (h *HTTPClient) RequestRaw(ctx context.Context, method, path string, opts *RequestOptions) (*http.Response, error) {
	resp, _, err := h.do(ctx, method, path, opts, true)
	return resp, err
}

func (h *HTTPClient) wait(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return ctx.Err()
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

func (h *HTTPClient) do(ctx context.Context, method, path string, o *RequestOptions, raw bool) (*http.Response, []byte, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if o == nil {
		o = &RequestOptions{}
	}
	method = strings.ToUpper(method)
	u := h.BaseURL + path + EncodeQuery(o.Query)
	label := method + " " + path
	var payload []byte
	if o.Body != nil {
		b, err := json.Marshal(o.Body)
		if err != nil {
			return nil, nil, fmt.Errorf("%w: could not encode the request body: %v", ErrInvalidArgument, err)
		}
		payload = b
	}
	retryable := idempotent[method]
	backoff := h.Backoff
	if backoff == nil {
		backoff = defaultBackoff
	}

	for attempt := 0; ; attempt++ {
		actx, cancel := context.WithCancel(ctx)
		var timedOut atomic.Bool
		timer := time.AfterFunc(h.Timeout, func() { timedOut.Store(true); cancel() })
		var rdr io.Reader
		if payload != nil {
			rdr = bytes.NewReader(payload)
		}
		req, err := http.NewRequestWithContext(actx, method, u, rdr)
		if err != nil {
			timer.Stop()
			cancel()
			return nil, nil, fmt.Errorf("%w: %v", ErrInvalidArgument, err)
		}
		req.Header.Set("Authorization", "Bearer "+h.key.v)
		if raw {
			req.Header.Set("Accept", "*/*")
		} else {
			req.Header.Set("Accept", "application/json")
		}
		req.Header.Set("User-Agent", h.UserAgent)
		if payload != nil {
			req.Header.Set("Content-Type", "application/json")
		}

		resp, err := h.client.Do(req)
		if err != nil {
			timer.Stop()
			cancel()
			if ctx.Err() != nil {
				return nil, nil, ctx.Err()
			}
			cause := err
			var ue *url.Error
			if errors.As(err, &ue) {
				cause = ue.Err
			}
			var e *Error
			if timedOut.Load() {
				e = &Error{Message: fmt.Sprintf("callio: no response within %s (%s)", h.Timeout, label), Request: label, kind: ErrTimeout, cause: cause}
			} else {
				e = &Error{Message: fmt.Sprintf("callio: could not reach %s (%s): %v", h.BaseURL, label, cause), Request: label, kind: ErrConnection, cause: cause}
			}
			if retryable && attempt < h.MaxRetries {
				if werr := h.wait(ctx, backoff(attempt, nil)); werr != nil {
					return nil, nil, werr
				}
				continue
			}
			return nil, nil, e
		}

		if resp.StatusCode >= 300 && resp.StatusCode < 400 {
			// Redirects are never followed: the Authorization header must not reach another host.
			_ = resp.Body.Close()
			timer.Stop()
			cancel()
			where := "another location"
			if loc, perr := url.Parse(resp.Header.Get("Location")); perr == nil && loc.Host != "" {
				where = loc.Scheme + "://" + loc.Host
			}
			return nil, nil, &Error{Status: resp.StatusCode, Request: label, kind: ErrRedirect,
				Message: fmt.Sprintf("callio: refusing to follow a redirect to %s (the API key is never sent on a redirect); check the base URL", where)}
		}
		ok := resp.StatusCode >= 200 && resp.StatusCode < 300
		if ok && raw {
			// A streamed body is handed over once its headers arrive; the timeout covers getting that far.
			timer.Stop()
			resp.Body = &cancelOnClose{ReadCloser: resp.Body, cancel: cancel}
			return resp, nil, nil
		}
		body, rerr := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		timer.Stop()
		cancel()
		if rerr != nil {
			if ctx.Err() != nil {
				return nil, nil, ctx.Err()
			}
			e := &Error{Status: resp.StatusCode, Message: fmt.Sprintf("callio: the response was cut off (%s)", label), Request: label, kind: ErrConnection, cause: rerr}
			if timedOut.Load() {
				e.kind = ErrTimeout
				e.Message = fmt.Sprintf("callio: no response within %s (%s)", h.Timeout, label)
			}
			if retryable && attempt < h.MaxRetries {
				if werr := h.wait(ctx, backoff(attempt, nil)); werr != nil {
					return nil, nil, werr
				}
				continue
			}
			return nil, nil, e
		}
		if ok {
			return resp, body, nil
		}

		retryAfter := ParseRetryAfter(resp.Header.Get("Retry-After"))
		if retryable && (resp.StatusCode == 429 || resp.StatusCode >= 500) && attempt < h.MaxRetries {
			if werr := h.wait(ctx, backoff(attempt, retryAfter)); werr != nil {
				return nil, nil, werr
			}
			continue
		}
		parsed := parseBody(body)
		msg := fmt.Sprintf("HTTP %d", resp.StatusCode)
		switch p := parsed.(type) {
		case map[string]any:
			if s, ok := p["error"].(string); ok {
				msg = s
			}
		case string:
			if p != "" {
				if len(p) > 200 {
					p = p[:200]
				}
				msg = p
			}
		}
		return nil, nil, errorFor(resp.StatusCode, msg, parsed, label, retryAfter)
	}
}

func parseBody(b []byte) any {
	if len(b) == 0 {
		return nil
	}
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		return string(b)
	}
	return v
}
