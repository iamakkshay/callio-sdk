package callio

// Unit tests against a scripted http.RoundTripper: no network. Run with `go test ./...`.

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

const testKey = "cio_abc123_s3cret-value"

type call struct {
	Method string
	URL    string
	Header http.Header
	JSON   any
}

type mockRT struct {
	t         *testing.T
	responses []func(*http.Request) (*http.Response, error)
	calls     []call
}

func (m *mockRT) RoundTrip(r *http.Request) (*http.Response, error) {
	c := call{Method: r.Method, URL: r.URL.String(), Header: r.Header.Clone()}
	if r.Body != nil {
		b, _ := io.ReadAll(r.Body)
		if len(b) > 0 {
			_ = json.Unmarshal(b, &c.JSON)
		}
	}
	m.calls = append(m.calls, c)
	if len(m.responses) == 0 {
		return nil, fmt.Errorf("unexpected request %s", r.URL)
	}
	f := m.responses[0]
	m.responses = m.responses[1:]
	return f(r)
}

func jsonResp(status int, body any, headers ...string) func(*http.Request) (*http.Response, error) {
	return func(r *http.Request) (*http.Response, error) {
		h := http.Header{"Content-Type": {"application/json"}}
		for i := 0; i+1 < len(headers); i += 2 {
			h.Set(headers[i], headers[i+1])
		}
		var b []byte
		if body != nil {
			b, _ = json.Marshal(body)
		}
		return &http.Response{StatusCode: status, Header: h, Body: io.NopCloser(bytes.NewReader(b)), Request: r}, nil
	}
}

type obj = map[string]any

func mock(t *testing.T, rs ...func(*http.Request) (*http.Response, error)) *mockRT {
	return &mockRT{t: t, responses: rs}
}

func client(t *testing.T, m *mockRT, opts ...Option) *Client {
	t.Helper()
	all := append([]Option{WithAPIKey(testKey), WithBaseURL("https://api.example.test/"), WithHTTPClient(&http.Client{Transport: m})}, opts...)
	c, err := New(all...)
	if err != nil {
		t.Fatal(err)
	}
	c.HTTP.Backoff = func(int, *time.Duration) time.Duration { return 0 }
	return c
}

var ctx = context.Background()

func eq(t *testing.T, got, want any) {
	t.Helper()
	gj, _ := json.Marshal(got)
	wj, _ := json.Marshal(want)
	if string(gj) != string(wj) {
		t.Fatalf("got %s, want %s", gj, wj)
	}
}

func TestSendsBearerJSONAndUserAgent(t *testing.T) {
	m := mock(t, jsonResp(201, obj{"user": obj{"username": "u1", "extension": "1001"}}))
	u, err := client(t, m).Users.Create(ctx, CreateUserParams{Username: "u1", DisplayName: "U One", UserType: UserTypeCustomer})
	if err != nil {
		t.Fatal(err)
	}
	eq(t, u.Extension, "1001")
	c := m.calls[0]
	eq(t, c.URL, "https://api.example.test/api/v1/users")
	eq(t, c.Method, "POST")
	eq(t, c.Header.Get("Authorization"), "Bearer "+testKey)
	eq(t, c.Header.Get("Content-Type"), "application/json")
	if !regexp.MustCompile(`^callio-server-go/` + regexp.QuoteMeta(Version) + ` go/`).MatchString(c.Header.Get("User-Agent")) {
		t.Fatal(c.Header.Get("User-Agent"))
	}
	eq(t, c.JSON, obj{"username": "u1", "displayName": "U One", "userType": "customer"})
}

func TestQueryAndPathEncoding(t *testing.T) {
	m := mock(t, jsonResp(200, obj{"users": []any{}}), jsonResp(200, obj{"events": []any{}, "next": 5}), jsonResp(200, obj{"user": obj{}}), jsonResp(200, obj{"recordings": []any{}}))
	c := client(t, m)
	if _, err := c.Users.List(ctx, ListUsersParams{Q: "sa ra", Type: UserTypeAgent}); err != nil {
		t.Fatal(err)
	}
	_, _ = c.Events.List(ctx, ListEventsParams{After: 5, Types: []string{"call.", "chat."}})
	_, _ = c.Users.Get(ctx, "a/b@c")
	_, _ = c.Recordings.List(ctx, ListRecordingsParams{From: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), MinDuration: 10})
	eq(t, m.calls[0].URL, "https://api.example.test/api/v1/users?q=sa+ra&type=agent")
	eq(t, m.calls[1].URL, "https://api.example.test/api/v1/events?after=5&types=call.%2Cchat.")
	eq(t, m.calls[2].URL, "https://api.example.test/api/v1/users/a%2Fb@c")
	eq(t, m.calls[3].URL, "https://api.example.test/api/v1/recordings?from=2026-01-01T00%3A00%3A00.000Z&minDuration=10")
}

func TestStatusesMapToTypedErrors(t *testing.T) {
	cases := []struct {
		status int
		kind   error
	}{{400, ErrValidation}, {401, ErrAuthentication}, {403, ErrPermissionDenied}, {404, ErrNotFound}, {409, ErrConflict}, {410, ErrGone}, {500, ErrServer}, {418, nil}}
	for _, tc := range cases {
		m := mock(t, jsonResp(tc.status, obj{"error": fmt.Sprintf("reason %d", tc.status)}))
		_, err := client(t, m, WithMaxRetries(0)).Orders.Get(ctx, "X")
		var ce *Error
		if !errors.As(err, &ce) {
			t.Fatalf("%d: %T", tc.status, err)
		}
		if tc.kind != nil && !errors.Is(err, tc.kind) {
			t.Fatalf("%d: kind %v", tc.status, ce.Kind())
		}
		if tc.kind == nil && ce.Kind() != nil {
			t.Fatalf("418 should have no kind")
		}
		eq(t, ce.Status, tc.status)
		eq(t, ce.Message, fmt.Sprintf("reason %d", tc.status))
		eq(t, ce.Request, "GET /api/v1/orders/X")
		if strings.Contains(fmt.Sprintf("%v %+v %#v", err, ce, ce), testKey) {
			t.Fatal("key leaked")
		}
	}
}

func TestIPAllowList403(t *testing.T) {
	m := mock(t, jsonResp(403, obj{"error": "this network (203.0.113.9) is not allowed to use this organisation's API"}))
	_, err := client(t, m).Users.List(ctx, ListUsersParams{})
	if !errors.Is(err, ErrPermissionDenied) || !strings.Contains(err.Error(), "not allowed") {
		t.Fatal(err)
	}
}

func TestGETRetriesHonouringRetryAfter(t *testing.T) {
	m := mock(t, jsonResp(429, obj{"error": "slow down"}, "Retry-After", "2"), jsonResp(503, obj{"error": "busy"}), jsonResp(200, obj{"orders": []obj{{"id": "A"}}}))
	c := client(t, m)
	var waits []string
	c.HTTP.Backoff = func(a int, ra *time.Duration) time.Duration {
		if ra == nil {
			waits = append(waits, fmt.Sprintf("%d:nil", a))
		} else {
			waits = append(waits, fmt.Sprintf("%d:%s", a, *ra))
		}
		return 0
	}
	orders, err := c.Orders.List(ctx, ListOrdersParams{})
	if err != nil {
		t.Fatal(err)
	}
	eq(t, orders[0].ID, "A")
	eq(t, len(m.calls), 3)
	eq(t, waits, []string{"0:2s", "1:nil"})
}

func TestGivesUpWithRateLimitRetryAfter(t *testing.T) {
	m := mock(t, jsonResp(429, obj{"error": "a"}, "Retry-After", "7"), jsonResp(429, obj{"error": "b"}, "Retry-After", "7"))
	_, err := client(t, m, WithMaxRetries(1)).CDR.List(ctx, ListCdrParams{})
	var ce *Error
	if !errors.As(err, &ce) || !errors.Is(err, ErrRateLimit) || ce.RetryAfter == nil || *ce.RetryAfter != 7*time.Second || ce.Status != 429 {
		t.Fatal(err)
	}
	eq(t, len(m.calls), 2)
}

func TestPostPatchNeverRetried(t *testing.T) {
	m1 := mock(t, jsonResp(503, obj{"error": "busy"}))
	_, err := client(t, m1).Orders.Create(ctx, CreateOrderParams{ID: "O1", Customer: "c"})
	if !errors.Is(err, ErrServer) {
		t.Fatal(err)
	}
	eq(t, len(m1.calls), 1)
	m2 := mock(t, jsonResp(429, obj{"error": "slow"}, "Retry-After", "1"))
	_, err = client(t, m2).Orders.Close(ctx, "O1")
	if !errors.Is(err, ErrRateLimit) {
		t.Fatal(err)
	}
	eq(t, len(m2.calls), 1)
}

func TestNetworkErrorsRetriedForGET(t *testing.T) {
	boom := func(*http.Request) (*http.Response, error) { return nil, errors.New("connection refused") }
	m := mock(t, boom, boom, boom)
	_, err := client(t, m).Groups.List(ctx)
	var ce *Error
	if !errors.As(err, &ce) || !errors.Is(err, ErrConnection) || errors.Is(err, ErrTimeout) || ce.Status != 0 || strings.Contains(err.Error(), testKey) {
		t.Fatal(err)
	}
	eq(t, len(m.calls), 3)
}

func TestTimesOut(t *testing.T) {
	hang := func(r *http.Request) (*http.Response, error) { <-r.Context().Done(); return nil, r.Context().Err() }
	m := mock(t, hang)
	_, err := client(t, m, WithTimeout(20*time.Millisecond), WithMaxRetries(0)).Users.Get(ctx, "x")
	if !errors.Is(err, ErrTimeout) || !errors.Is(err, ErrConnection) {
		t.Fatal(err)
	}
}

func TestCallerContextCancelIsReturnedAsIs(t *testing.T) {
	hang := func(r *http.Request) (*http.Response, error) { <-r.Context().Done(); return nil, r.Context().Err() }
	m := mock(t, hang)
	cctx, cancel := context.WithTimeout(ctx, 10*time.Millisecond)
	defer cancel()
	_, err := client(t, m).Users.Get(cctx, "x")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal(err)
	}
	eq(t, len(m.calls), 1)
}

func TestForUserCreatesThenIssues(t *testing.T) {
	m := mock(t, jsonResp(201, obj{"user": obj{"username": "c1"}}), jsonResp(200, obj{"token": "jwt", "userType": "customer", "expiresAt": "later"}))
	tok, err := client(t, m).Tokens.ForUser(ctx, "c1", ForUserOptions{DisplayName: "C", UserType: UserTypeCustomer, TTLSec: 600})
	if err != nil {
		t.Fatal(err)
	}
	eq(t, tok, UserToken{Token: "jwt", UserType: "customer", ExpiresAt: "later", Created: true})
	eq(t, m.calls[0].JSON, obj{"username": "c1", "displayName": "C", "userType": "customer"})
	eq(t, m.calls[1].JSON, obj{"username": "c1", "ttlSec": 600})
}

func TestForUser409MeansExists(t *testing.T) {
	m := mock(t, jsonResp(409, obj{"error": "user exists"}), jsonResp(200, obj{"token": "jwt", "userType": "agent", "expiresAt": "x"}))
	tok, err := client(t, m).Tokens.ForUser(ctx, "a1", ForUserOptions{UserType: UserTypeAgent})
	if err != nil || tok.Created || tok.Token != "jwt" {
		t.Fatal(tok, err)
	}
}

func TestForUserPropagatesOtherErrors(t *testing.T) {
	m := mock(t, jsonResp(403, obj{"error": "seat quota reached"}))
	_, err := client(t, m).Tokens.ForUser(ctx, "a1", ForUserOptions{})
	if !errors.Is(err, ErrPermissionDenied) {
		t.Fatal(err)
	}
	eq(t, len(m.calls), 1)
}

func TestOrderHelpersPatch(t *testing.T) {
	o := obj{"order": obj{"id": "O1"}}
	m := mock(t, jsonResp(200, o), jsonResp(200, o), jsonResp(200, o), jsonResp(200, o), jsonResp(200, o))
	c := client(t, m)
	_, _ = c.Orders.Assign(ctx, "O1", "drv")
	_, _ = c.Orders.Assign(ctx, "O1", "")
	_, _ = c.Orders.Close(ctx, "O1")
	_, _ = c.Orders.Reopen(ctx, "O1")
	_, _ = c.Orders.Update(ctx, "O1", UpdateOrderParams{Label: Null[string]()})
	var got [][]any
	for _, x := range m.calls {
		got = append(got, []any{x.Method, x.JSON})
	}
	eq(t, got, [][]any{{"PATCH", obj{"agent": "drv"}}, {"PATCH", obj{"agent": nil}}, {"PATCH", obj{"status": "closed"}}, {"PATCH", obj{"status": "active"}}, {"PATCH", obj{"label": nil}}})
}

func TestUsersDisableEnableAndUpdateFields(t *testing.T) {
	u := obj{"user": obj{"username": "u1"}}
	m := mock(t, jsonResp(200, u), jsonResp(200, u), jsonResp(200, u))
	c := client(t, m)
	_, _ = c.Users.Disable(ctx, "u1")
	_, _ = c.Users.Enable(ctx, "u1")
	_, _ = c.Users.Update(ctx, "u1", UpdateUserParams{DisplayName: "N", Segment: Null[string](), Phone: Set("+966500000000")})
	eq(t, m.calls[0].JSON, obj{"disabled": true})
	eq(t, m.calls[1].JSON, obj{"disabled": false})
	eq(t, m.calls[2].JSON, obj{"displayName": "N", "segment": nil, "phone": "+966500000000"})
}

func TestUsersDeleteSendsReason(t *testing.T) {
	m := mock(t, jsonResp(200, obj{"ok": true, "alias": "erased-1", "removed": obj{}, "recordingsKeptOnLegalHold": []any{}}))
	r, err := client(t, m).Users.Delete(ctx, "u1", "customer asked")
	if err != nil {
		t.Fatal(err)
	}
	eq(t, r.Alias, "erased-1")
	eq(t, m.calls[0].Method, "DELETE")
	eq(t, m.calls[0].JSON, obj{"reason": "customer asked"})
}

func TestRecordingAudioStreamsAndDownloads(t *testing.T) {
	data := []byte{79, 103, 103, 83, 1, 2, 3}
	audio := func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"audio/ogg"}, "Content-Length": {"7"}}, Body: io.NopCloser(bytes.NewReader(data)), Request: r}, nil
	}
	m := mock(t, audio, audio)
	c := client(t, m)
	a, err := c.Recordings.Audio(ctx, "rec-1", "QA review — طلب")
	if err != nil {
		t.Fatal(err)
	}
	eq(t, a.ContentType, "audio/ogg")
	eq(t, a.ContentLength, int64(7))
	got, _ := io.ReadAll(a.Body)
	_ = a.Body.Close()
	if !bytes.Equal(got, data) {
		t.Fatal(got)
	}
	u, _ := url.Parse(m.calls[0].URL)
	eq(t, u.Query().Get("reason"), "QA review — طلب")
	eq(t, m.calls[0].Header.Get("Accept"), "*/*")
	file := filepath.Join(t.TempDir(), "a.ogg")
	n, err := c.Recordings.Download(ctx, "rec-1", file, "dispute 123")
	if err != nil || n != 7 {
		t.Fatal(n, err)
	}
	b, _ := os.ReadFile(file)
	if !bytes.Equal(b, data) {
		t.Fatal(b)
	}
}

func TestRecordingAudioRequiresReasonAndMaps410(t *testing.T) {
	m := mock(t, jsonResp(410, obj{"error": "this recording was deleted"}))
	c := client(t, m)
	if _, err := c.Recordings.Audio(ctx, "r", "no"); !errors.Is(err, ErrInvalidArgument) {
		t.Fatal(err)
	}
	if _, err := c.Recordings.Transcript(ctx, "r", "    "); !errors.Is(err, ErrInvalidArgument) {
		t.Fatal(err)
	}
	if _, err := c.Recordings.Audio(ctx, "r", "audit check"); !errors.Is(err, ErrGone) {
		t.Fatal(err)
	}
	eq(t, len(m.calls), 1)
	if _, err := c.Users.Get(ctx, ""); !errors.Is(err, ErrInvalidArgument) {
		t.Fatal(err)
	}
}

func TestRejectsDotPathSegments(t *testing.T) {
	m := mock(t)
	c := client(t, m)
	for _, id := range []string{"", ".", ".."} {
		if _, err := c.Users.Get(ctx, id); !errors.Is(err, ErrInvalidArgument) {
			t.Fatalf("%q: %v", id, err)
		}
		if _, err := c.Orders.Close(ctx, id); !errors.Is(err, ErrInvalidArgument) {
			t.Fatalf("%q: %v", id, err)
		}
		if _, err := c.Groups.Delete(ctx, id); !errors.Is(err, ErrInvalidArgument) {
			t.Fatalf("%q: %v", id, err)
		}
	}
	eq(t, len(m.calls), 0)
}

func TestRedirectsAreRefused(t *testing.T) {
	m := mock(t, jsonResp(302, nil, "Location", "https://evil.example/steal?x=1"), jsonResp(200, obj{"users": []any{}}))
	_, err := client(t, m).Users.List(ctx, ListUsersParams{})
	var ce *Error
	if !errors.As(err, &ce) || !errors.Is(err, ErrRedirect) || ce.Status != 302 || !strings.Contains(err.Error(), "https://evil.example") {
		t.Fatal(err)
	}
	eq(t, len(m.calls), 1) // not followed, not retried
	// A caller-supplied client that would follow redirects is overridden too.
	m2 := mock(t, jsonResp(301, nil, "Location", "https://evil.example/"), jsonResp(200, obj{"users": []any{}}))
	hc := &http.Client{Transport: m2, CheckRedirect: func(*http.Request, []*http.Request) error { return nil }}
	c2, _ := New(WithAPIKey(testKey), WithBaseURL("https://api.example.test"), WithHTTPClient(hc))
	if _, err := c2.Users.List(ctx, ListUsersParams{}); !errors.Is(err, ErrRedirect) {
		t.Fatal(err)
	}
	eq(t, len(m2.calls), 1)
	if hc.CheckRedirect == nil {
		t.Fatal("caller's client was modified")
	}
}

func TestTranscript(t *testing.T) {
	m := mock(t, jsonResp(200, obj{"transcript": obj{"text": "hello", "language": "en", "segments": []obj{{"start": 0, "end": 1.5, "text": "hello"}}}}))
	tr, err := client(t, m).Recordings.Transcript(ctx, "r1", "QA review")
	if err != nil || tr.Text != "hello" || tr.Segments[0].End != 1.5 {
		t.Fatal(tr, err)
	}
	u, _ := url.Parse(m.calls[0].URL)
	eq(t, u.Query().Get("reason"), "QA review")
}

func TestEventsIteratePagesUntilCaughtUp(t *testing.T) {
	m := mock(t, jsonResp(200, obj{"events": []obj{{"id": 1}, {"id": 2}}, "next": 2}), jsonResp(200, obj{"events": []obj{{"id": 3}}, "next": 3}), jsonResp(200, obj{"events": []any{}, "next": 3}))
	var ids []int64
	for e, err := range client(t, m).Events.Iterate(ctx, ListEventsParams{Limit: 2}) {
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, e.ID)
	}
	eq(t, ids, []int64{1, 2, 3})
	var afters []string
	for _, c := range m.calls {
		u, _ := url.Parse(c.URL)
		afters = append(afters, u.Query().Get("after"))
	}
	eq(t, afters, []string{"0", "2", "3"})
}

func TestEventsIterateYieldsError(t *testing.T) {
	m := mock(t, jsonResp(401, obj{"error": "bad key"}))
	n := 0
	for _, err := range client(t, m).Events.Iterate(ctx, ListEventsParams{}) {
		n++
		if !errors.Is(err, ErrAuthentication) {
			t.Fatal(err)
		}
	}
	eq(t, n, 1)
}

func TestRawRequestEscapeHatch(t *testing.T) {
	m := mock(t, jsonResp(200, obj{"hello": "world"}))
	var out map[string]string
	if err := client(t, m).HTTP.Request(ctx, "GET", "/api/v1/whatever", &RequestOptions{Query: Query{"x": 1}}, &out); err != nil {
		t.Fatal(err)
	}
	eq(t, out["hello"], "world")
	eq(t, m.calls[0].URL, "https://api.example.test/api/v1/whatever?x=1")
}

func TestKeyNeverFormatted(t *testing.T) {
	c := client(t, mock(t))
	for _, s := range []string{fmt.Sprint(c), fmt.Sprintf("%+v", c), fmt.Sprintf("%#v", c), fmt.Sprintf("%+v", *c.HTTP), fmt.Sprintf("%#v", *c.HTTP), fmt.Sprintf("%v", c.HTTP)} {
		if strings.Contains(s, testKey) {
			t.Fatal("key leaked: " + s)
		}
	}
	b, _ := json.Marshal(c)
	if bytes.Contains(b, []byte(testKey)) {
		t.Fatal("key in JSON")
	}
}

func TestConstructorValidatesAndReadsEnv(t *testing.T) {
	t.Setenv("CALLIO_API_KEY", "")
	t.Setenv("CALLIO_BASE_URL", "")
	if _, err := New(WithBaseURL("https://x")); err == nil || !strings.Contains(err.Error(), "apiKey is required") {
		t.Fatal(err)
	}
	if _, err := New(WithAPIKey(testKey)); err == nil || !strings.Contains(err.Error(), "baseURL is required") {
		t.Fatal(err)
	}
	if _, err := New(WithAPIKey(testKey), WithBaseURL("api.example.sa")); err == nil || !strings.Contains(err.Error(), "https") {
		t.Fatal(err)
	}
	if _, err := New(WithAPIKey(testKey), WithBaseURL("http://localhost:8080")); err == nil || !strings.Contains(err.Error(), "WithAllowInsecure") {
		t.Fatal("http:// accepted without WithAllowInsecure", err)
	}
	if c, err := New(WithAPIKey(testKey), WithBaseURL("http://localhost:8080/"), WithAllowInsecure(true)); err != nil || c.HTTP.BaseURL != "http://localhost:8080" {
		t.Fatal(err)
	}
	if _, err := New(WithAPIKey(testKey), WithBaseURL("ftp://x"), WithAllowInsecure(true)); err == nil {
		t.Fatal("ftp accepted")
	}
	t.Setenv("CALLIO_API_KEY", testKey)
	t.Setenv("CALLIO_BASE_URL", "https://env.example/")
	c, err := New()
	if err != nil {
		t.Fatal(err)
	}
	eq(t, c.HTTP.BaseURL, "https://env.example")
}

func TestParseRetryAfter(t *testing.T) {
	if d := ParseRetryAfter("3"); d == nil || *d != 3*time.Second {
		t.Fatal(d)
	}
	if d := ParseRetryAfter(time.Now().Add(5 * time.Second).UTC().Format(http.TimeFormat)); d == nil || *d < 4*time.Second || *d > 6*time.Second {
		t.Fatal(d)
	}
	if ParseRetryAfter("") != nil || ParseRetryAfter("soon") != nil || ParseRetryAfter("-1") != nil {
		t.Fatal("bad")
	}
}

// ---- webhooks ----

const whSecret = "whsec_test"

var whBody = []byte(`{"tenantId":"lab","type":"order.assigned","order":{"id":"O1","agent":"drv"},"by":"apikey:abc","at":"2026-01-01T00:00:00Z"}`)

func whSig() string {
	m := hmac.New(sha256.New, []byte(whSecret))
	m.Write(whBody)
	return "sha256=" + hex.EncodeToString(m.Sum(nil))
}

func TestVerifyWebhookAccepts(t *testing.T) {
	sig := whSig()
	eq(t, SignWebhook(whBody, whSecret), sig)
	if !VerifyWebhook(whBody, sig, whSecret) || !VerifyWebhook(whBody, "  "+sig+" ", whSecret) {
		t.Fatal("rejected")
	}
	if !VerifyWebhook(whBody, "sha256="+strings.ToUpper(sig[7:]), whSecret) {
		t.Fatal("uppercase hex rejected")
	}
}

func TestVerifyWebhookRejects(t *testing.T) {
	sig := whSig()
	if VerifyWebhook(append(append([]byte{}, whBody...), ' '), sig, whSecret) || VerifyWebhook(whBody, sig, "other") {
		t.Fatal("accepted")
	}
	for _, h := range []string{"", "sha256=", "sha256=zz", sig[7:], "sha1=" + sig[7:], sig + "00"} {
		if VerifyWebhook(whBody, h, whSecret) {
			t.Fatal("accepted " + h)
		}
	}
	defer func() {
		if recover() == nil {
			t.Fatal("empty secret should panic")
		}
	}()
	VerifyWebhook(whBody, sig, "")
}

func TestParseWebhook(t *testing.T) {
	ev, err := ParseWebhook(whBody, whSig(), whSecret)
	if err != nil {
		t.Fatal(err)
	}
	if !ev.IsOrderEvent() || ev.Order == nil || *ev.Order.Agent != "drv" || ev.By != "apikey:abc" || ev.TenantID != "lab" {
		t.Fatalf("%+v", ev)
	}
	if _, err := ParseWebhook(whBody, "sha256="+strings.Repeat("0", 64), whSecret); !errors.Is(err, ErrWebhookVerification) {
		t.Fatal(err)
	}
	notJSON := []byte("nope")
	if _, err := ParseWebhook(notJSON, SignWebhook(notJSON, whSecret), whSecret); !errors.Is(err, ErrWebhookVerification) {
		t.Fatal(err)
	}
	noType := []byte(`{"a":1}`)
	if _, err := ParseWebhook(noType, SignWebhook(noType, whSecret), whSecret); !errors.Is(err, ErrWebhookVerification) {
		t.Fatal(err)
	}
}

var whBodyV1 = []byte(`{"id":"evt_01","tenantId":"lab","type":"recording.ready","recordingId":"rec-9","durationSec":42,"at":"2026-01-01T00:00:00Z"}`)

func v1Headers(body []byte, ts int64, secret string) http.Header {
	h := http.Header{}
	h.Set("x-callio-timestamp", fmt.Sprint(ts))
	h.Set("x-callio-signature", SignWebhookV1(body, ts, secret))
	h.Set("x-ngx-signature", SignWebhook(body, secret))
	return h
}

func TestVerifyWebhookRequestV1(t *testing.T) {
	now := time.Now().Unix()
	h := v1Headers(whBodyV1, now, whSecret)
	// The platform's construction: HMAC(secret, ts + "." + body).
	m := hmac.New(sha256.New, []byte(whSecret))
	m.Write([]byte(fmt.Sprintf("%d.%s", now, whBodyV1)))
	eq(t, h.Get(SignatureV1Header), "v1="+hex.EncodeToString(m.Sum(nil)))
	if err := VerifyWebhookRequest(whBodyV1, h, whSecret, nil); err != nil {
		t.Fatal(err)
	}
	ev, err := ParseWebhookRequest(whBodyV1, h, whSecret, nil)
	if err != nil || ev.ID != "evt_01" || !ev.IsRecordingReady() || ev.RecordingID != "rec-9" {
		t.Fatal(ev, err)
	}
	// Rotation: any of several v1 signatures may match.
	h2 := h.Clone()
	h2.Set(SignatureV1Header, "v1="+strings.Repeat("0", 64)+", "+h.Get(SignatureV1Header))
	if err := VerifyWebhookRequest(whBodyV1, h2, whSecret, nil); err != nil {
		t.Fatal(err)
	}
}

func TestVerifyWebhookRequestRejects(t *testing.T) {
	now := time.Now().Unix()
	bad := func(name string, body []byte, h http.Header, o *WebhookOptions) {
		t.Helper()
		err := VerifyWebhookRequest(body, h, whSecret, o)
		var ce *Error
		if !errors.Is(err, ErrWebhookVerification) || !errors.As(err, &ce) || ce.Status != 401 {
			t.Fatalf("%s: %v", name, err)
		}
		if _, err := ParseWebhookRequest(body, h, whSecret, o); !errors.Is(err, ErrWebhookVerification) {
			t.Fatalf("%s (parse): %v", name, err)
		}
	}
	bad("tampered", append(append([]byte{}, whBodyV1...), ' '), v1Headers(whBodyV1, now, whSecret), nil)
	bad("wrong secret", whBodyV1, v1Headers(whBodyV1, now, "other"), nil)
	bad("stale (replay)", whBodyV1, v1Headers(whBodyV1, now-301, whSecret), nil)
	bad("future", whBodyV1, v1Headers(whBodyV1, now+301, whSecret), nil)
	h := v1Headers(whBodyV1, now, whSecret)
	h.Set(TimestampHeader, fmt.Sprint(now+1)) // timestamp swapped after signing
	bad("swapped timestamp", whBodyV1, h, nil)
	h = v1Headers(whBodyV1, now, whSecret)
	h.Set(TimestampHeader, "yesterday")
	bad("malformed timestamp", whBodyV1, h, nil)
	h = v1Headers(whBodyV1, now, whSecret)
	h.Del(SignatureV1Header)
	bad("timestamp but no v1", whBodyV1, h, &WebhookOptions{AllowLegacy: true})
	h = v1Headers(whBodyV1, now, whSecret)
	h.Del(TimestampHeader)
	bad("legacy only, not allowed", whBodyV1, h, nil)
	// Tolerance is configurable.
	if err := VerifyWebhookRequest(whBodyV1, v1Headers(whBodyV1, now-600, whSecret), whSecret, &WebhookOptions{Tolerance: 15 * time.Minute}); err != nil {
		t.Fatal(err)
	}
	bad("custom tolerance", whBodyV1, v1Headers(whBodyV1, now-60, whSecret), &WebhookOptions{Tolerance: 30 * time.Second})
	fixed := time.Unix(now+1000, 0)
	bad("clock", whBodyV1, v1Headers(whBodyV1, now, whSecret), &WebhookOptions{Now: func() time.Time { return fixed }})
	if err := VerifyWebhookRequest(whBodyV1, v1Headers(whBodyV1, now, whSecret), "", nil); !errors.Is(err, ErrInvalidArgument) {
		t.Fatal(err)
	}
}

func TestVerifyWebhookRequestAllowLegacy(t *testing.T) {
	h := http.Header{}
	h.Set(SignatureHeader, SignWebhook(whBodyV1, whSecret))
	if err := VerifyWebhookRequest(whBodyV1, h, whSecret, &WebhookOptions{AllowLegacy: true}); err != nil {
		t.Fatal(err)
	}
	h.Set(SignatureHeader, SignWebhook(whBodyV1, "other"))
	if err := VerifyWebhookRequest(whBodyV1, h, whSecret, &WebhookOptions{AllowLegacy: true}); !errors.Is(err, ErrWebhookVerification) {
		t.Fatal(err)
	}
}

func TestVersion(t *testing.T) {
	if !regexp.MustCompile(`^\d+\.\d+\.\d+$`).MatchString(Version) || Version != "0.1.0" {
		t.Fatal(Version)
	}
}
