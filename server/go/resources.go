package callio

// One type per API namespace, mirroring /api/v1.

import (
	"context"
	"errors"
	"io"
	"iter"
	"net/url"
	"os"
	"strconv"
	"strings"
)

func seg(s string) (string, error) {
	if s == "" || s == "." || s == ".." {
		return "", invalidArg("an id / username is required (and cannot be \".\" or \"..\")")
	}
	return url.PathEscape(s), nil
}

func reasonOf(r string) (string, error) {
	r = strings.TrimSpace(r)
	if len([]rune(r)) < 5 {
		return "", invalidArg("a reason of at least 5 characters is required to fetch a recording")
	}
	return r, nil
}

func addStr(q Query, k, v string) {
	if v != "" {
		q[k] = v
	}
}

func addInt(q Query, k string, v int) {
	if v != 0 {
		q[k] = v
	}
}

// Users manages app users.
type Users struct{ h *HTTPClient }

// List searches users.
func (u *Users) List(ctx context.Context, p ListUsersParams) ([]User, error) {
	q := Query{}
	addStr(q, "q", p.Q)
	addStr(q, "type", string(p.Type))
	addStr(q, "status", p.Status)
	addStr(q, "segment", p.Segment)
	addInt(q, "limit", p.Limit)
	var r struct {
		Users []User `json:"users"`
	}
	if err := u.h.Request(ctx, "GET", "/api/v1/users", &RequestOptions{Query: q}, &r); err != nil {
		return nil, err
	}
	return r.Users, nil
}

// Create creates a user. ErrConflict (409) if the username exists, ErrPermissionDenied (403) at the seat quota.
func (u *Users) Create(ctx context.Context, p CreateUserParams) (*CreatedUser, error) {
	var r struct {
		User CreatedUser `json:"user"`
	}
	if err := u.h.Request(ctx, "POST", "/api/v1/users", &RequestOptions{Body: p}, &r); err != nil {
		return nil, err
	}
	return &r.User, nil
}

// Get reads one user.
func (u *Users) Get(ctx context.Context, username string) (*User, error) {
	s, err := seg(username)
	if err != nil {
		return nil, err
	}
	var r struct {
		User User `json:"user"`
	}
	if err := u.h.Request(ctx, "GET", "/api/v1/users/"+s, nil, &r); err != nil {
		return nil, err
	}
	return &r.User, nil
}

// Update changes a user. Changing the type or disabling ends the user's sessions.
func (u *Users) Update(ctx context.Context, username string, p UpdateUserParams) (*User, error) {
	s, err := seg(username)
	if err != nil {
		return nil, err
	}
	var r struct {
		User User `json:"user"`
	}
	if err := u.h.Request(ctx, "PATCH", "/api/v1/users/"+s, &RequestOptions{Body: p}, &r); err != nil {
		return nil, err
	}
	return &r.User, nil
}

// Disable disables a user (and ends their sessions).
func (u *Users) Disable(ctx context.Context, username string) (*User, error) {
	return u.Update(ctx, username, UpdateUserParams{Disabled: Ptr(true)})
}

// Enable re-enables a user.
func (u *Users) Enable(ctx context.Context, username string) (*User, error) {
	return u.Update(ctx, username, UpdateUserParams{Disabled: Ptr(false)})
}

// SignOut ends every session the user has open.
func (u *Users) SignOut(ctx context.Context, username string) (*OK, error) {
	s, err := seg(username)
	if err != nil {
		return nil, err
	}
	var r OK
	if err := u.h.Request(ctx, "POST", "/api/v1/users/"+s+"/sign-out", nil, &r); err != nil {
		return nil, err
	}
	return &r, nil
}

// Export is the PDPL access request: everything held about the user.
func (u *Users) Export(ctx context.Context, username string) (UserExport, error) {
	s, err := seg(username)
	if err != nil {
		return nil, err
	}
	var r UserExport
	if err := u.h.Request(ctx, "GET", "/api/v1/users/"+s+"/export", nil, &r); err != nil {
		return nil, err
	}
	return r, nil
}

// Delete is the PDPL erasure: it deletes the account and its data (recordings on legal hold are kept).
// Irreversible.
func (u *Users) Delete(ctx context.Context, username, reason string) (*ErasureResult, error) {
	s, err := seg(username)
	if err != nil {
		return nil, err
	}
	var r ErasureResult
	if err := u.h.Request(ctx, "DELETE", "/api/v1/users/"+s, &RequestOptions{Body: map[string]string{"reason": reason}}, &r); err != nil {
		return nil, err
	}
	return &r, nil
}

// Tokens issues app tokens.
type Tokens struct {
	h     *HTTPClient
	users *Users
}

// Create issues a short-lived app token for an existing user (60–3600 s, default 900).
func (t *Tokens) Create(ctx context.Context, p CreateTokenParams) (*Token, error) {
	var r Token
	if err := t.h.Request(ctx, "POST", "/api/v1/tokens", &RequestOptions{Body: p}, &r); err != nil {
		return nil, err
	}
	return &r, nil
}

// ForUser is the common job: make sure the app user exists, then issue their token. It creates the
// user if missing (a 409 means they already exist, which is fine). An existing user's display name and
// type are left as they are; check UserType on the result if it matters.
func (t *Tokens) ForUser(ctx context.Context, username string, o ForUserOptions) (*UserToken, error) {
	created := false
	_, err := t.users.Create(ctx, CreateUserParams{Username: username, DisplayName: o.DisplayName, UserType: o.UserType, Phone: o.Phone})
	if err == nil {
		created = true
	} else if !errors.Is(err, ErrConflict) {
		return nil, err
	}
	tok, err := t.Create(ctx, CreateTokenParams{Username: username, TTLSec: o.TTLSec, DeviceID: o.DeviceID})
	if err != nil {
		return nil, err
	}
	return &UserToken{Token: tok.Token, UserType: tok.UserType, ExpiresAt: tok.ExpiresAt, Created: created}, nil
}

// Orders links customers and agents.
type Orders struct{ h *HTTPClient }

func (o *Orders) one(ctx context.Context, method, path string, body any) (*Order, error) {
	var r struct {
		Order Order `json:"order"`
	}
	var opts *RequestOptions
	if body != nil {
		opts = &RequestOptions{Body: body}
	}
	if err := o.h.Request(ctx, method, path, opts, &r); err != nil {
		return nil, err
	}
	return &r.Order, nil
}

// Create creates an order. ErrConflict if the id exists, ErrValidation for an unknown customer/agent
// or a wrong user type.
func (o *Orders) Create(ctx context.Context, p CreateOrderParams) (*Order, error) {
	return o.one(ctx, "POST", "/api/v1/orders", p)
}

// List lists orders.
func (o *Orders) List(ctx context.Context, p ListOrdersParams) ([]Order, error) {
	q := Query{}
	addStr(q, "status", string(p.Status))
	addStr(q, "user", p.User)
	addInt(q, "limit", p.Limit)
	var r struct {
		Orders []Order `json:"orders"`
	}
	if err := o.h.Request(ctx, "GET", "/api/v1/orders", &RequestOptions{Query: q}, &r); err != nil {
		return nil, err
	}
	return r.Orders, nil
}

// Get reads one order.
func (o *Orders) Get(ctx context.Context, id string) (*Order, error) {
	s, err := seg(id)
	if err != nil {
		return nil, err
	}
	return o.one(ctx, "GET", "/api/v1/orders/"+s, nil)
}

// Update reassigns (Agent: Set(...)), unassigns (Agent: Null[string]()), closes or reopens (Status), relabels.
func (o *Orders) Update(ctx context.Context, id string, p UpdateOrderParams) (*Order, error) {
	s, err := seg(id)
	if err != nil {
		return nil, err
	}
	return o.one(ctx, "PATCH", "/api/v1/orders/"+s, p)
}

// Assign sets the order's agent; an empty agent unassigns it.
func (o *Orders) Assign(ctx context.Context, id, agent string) (*Order, error) {
	if agent == "" {
		return o.Unassign(ctx, id)
	}
	return o.Update(ctx, id, UpdateOrderParams{Agent: Set(agent)})
}

// Unassign removes the order's agent.
func (o *Orders) Unassign(ctx context.Context, id string) (*Order, error) {
	return o.Update(ctx, id, UpdateOrderParams{Agent: Null[string]()})
}

// Close closes the order.
func (o *Orders) Close(ctx context.Context, id string) (*Order, error) {
	return o.Update(ctx, id, UpdateOrderParams{Status: OrderClosed})
}

// Reopen reopens the order.
func (o *Orders) Reopen(ctx context.Context, id string) (*Order, error) {
	return o.Update(ctx, id, UpdateOrderParams{Status: OrderActive})
}

// Recordings reads call recordings.
type Recordings struct{ h *HTTPClient }

// RecordingAudio is an open audio download (stereo Ogg/Opus, caller left). Read Body and close it.
type RecordingAudio struct {
	Body        io.ReadCloser
	ContentType string
	// ContentLength is -1 when unknown.
	ContentLength int64
}

// List searches recordings.
func (r *Recordings) List(ctx context.Context, p ListRecordingsParams) ([]Recording, error) {
	q := Query{}
	if !p.From.IsZero() {
		q["from"] = p.From
	}
	if !p.To.IsZero() {
		q["to"] = p.To
	}
	addStr(q, "user", p.User)
	addStr(q, "callId", p.CallID)
	addStr(q, "orderId", p.OrderID)
	addInt(q, "minDuration", p.MinDuration)
	addInt(q, "maxDuration", p.MaxDuration)
	addStr(q, "status", p.Status)
	addInt(q, "limit", p.Limit)
	var out struct {
		Recordings []Recording `json:"recordings"`
	}
	if err := r.h.Request(ctx, "GET", "/api/v1/recordings", &RequestOptions{Query: q}, &out); err != nil {
		return nil, err
	}
	return out.Recordings, nil
}

// Get reads a recording's metadata.
func (r *Recordings) Get(ctx context.Context, id string) (*Recording, error) {
	s, err := seg(id)
	if err != nil {
		return nil, err
	}
	var out struct {
		Recording Recording `json:"recording"`
	}
	if err := r.h.Request(ctx, "GET", "/api/v1/recordings/"+s, nil, &out); err != nil {
		return nil, err
	}
	return &out.Recording, nil
}

// Audio opens the audio as a stream. The reason (at least 5 characters) is required and goes into the
// recording's access trail. Close Body promptly.
func (r *Recordings) Audio(ctx context.Context, id, reason string) (*RecordingAudio, error) {
	s, err := seg(id)
	if err != nil {
		return nil, err
	}
	rs, err := reasonOf(reason)
	if err != nil {
		return nil, err
	}
	resp, err := r.h.RequestRaw(ctx, "GET", "/api/v1/recordings/"+s+"/audio", &RequestOptions{Query: Query{"reason": rs}})
	if err != nil {
		return nil, err
	}
	ct := resp.Header.Get("Content-Type")
	if ct == "" {
		ct = "audio/ogg"
	}
	n := int64(-1)
	if v := resp.Header.Get("Content-Length"); v != "" {
		if x, err := strconv.ParseInt(v, 10, 64); err == nil {
			n = x
		}
	}
	return &RecordingAudio{Body: resp.Body, ContentType: ct, ContentLength: n}, nil
}

// DownloadTo streams the audio into w and returns the number of bytes written.
func (r *Recordings) DownloadTo(ctx context.Context, id string, w io.Writer, reason string) (int64, error) {
	a, err := r.Audio(ctx, id, reason)
	if err != nil {
		return 0, err
	}
	defer a.Body.Close()
	return io.Copy(w, a.Body)
}

// Download streams the audio straight to a file and returns the number of bytes written.
func (r *Recordings) Download(ctx context.Context, id, path, reason string) (int64, error) {
	a, err := r.Audio(ctx, id, reason)
	if err != nil {
		return 0, err
	}
	defer a.Body.Close()
	f, err := os.Create(path)
	if err != nil {
		return 0, err
	}
	n, err := io.Copy(f, a.Body)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return n, err
}

// Transcript reads the transcript; same rules as the audio (a reason, and the read is logged).
// ErrNotFound while it is still being transcribed.
func (r *Recordings) Transcript(ctx context.Context, id, reason string) (*Transcript, error) {
	s, err := seg(id)
	if err != nil {
		return nil, err
	}
	rs, err := reasonOf(reason)
	if err != nil {
		return nil, err
	}
	var out struct {
		Transcript Transcript `json:"transcript"`
	}
	if err := r.h.Request(ctx, "GET", "/api/v1/recordings/"+s+"/transcript", &RequestOptions{Query: Query{"reason": rs}}, &out); err != nil {
		return nil, err
	}
	return &out.Transcript, nil
}

// Groups manages group chats.
type Groups struct{ h *HTTPClient }

func (g *Groups) one(ctx context.Context, method, path string, body any) (*Group, error) {
	var r struct {
		Group Group `json:"group"`
	}
	var opts *RequestOptions
	if body != nil {
		opts = &RequestOptions{Body: body}
	}
	if err := g.h.Request(ctx, method, path, opts, &r); err != nil {
		return nil, err
	}
	return &r.Group, nil
}

// Create creates a group chat (2–50 members).
func (g *Groups) Create(ctx context.Context, p CreateGroupParams) (*Group, error) {
	return g.one(ctx, "POST", "/api/v1/groups", p)
}

// List lists group chats.
func (g *Groups) List(ctx context.Context) ([]Group, error) {
	var r struct {
		Groups []Group `json:"groups"`
	}
	if err := g.h.Request(ctx, "GET", "/api/v1/groups", nil, &r); err != nil {
		return nil, err
	}
	return r.Groups, nil
}

// Get reads one group chat.
func (g *Groups) Get(ctx context.Context, id string) (*Group, error) {
	s, err := seg(id)
	if err != nil {
		return nil, err
	}
	return g.one(ctx, "GET", "/api/v1/groups/"+s, nil)
}

// Update renames, adds or removes members. Members added later see messages from when they joined.
func (g *Groups) Update(ctx context.Context, id string, p UpdateGroupParams) (*Group, error) {
	s, err := seg(id)
	if err != nil {
		return nil, err
	}
	return g.one(ctx, "PATCH", "/api/v1/groups/"+s, p)
}

// Delete deletes the group and its messages.
func (g *Groups) Delete(ctx context.Context, id string) (*OK, error) {
	s, err := seg(id)
	if err != nil {
		return nil, err
	}
	var r OK
	if err := g.h.Request(ctx, "DELETE", "/api/v1/groups/"+s, nil, &r); err != nil {
		return nil, err
	}
	return &r, nil
}

// Events reads the event feed (BI).
type Events struct{ h *HTTPClient }

func (e *Events) page(ctx context.Context, p ListEventsParams, sendAfter bool) (*EventPage, error) {
	q := Query{}
	if sendAfter || p.After != 0 {
		q["after"] = p.After
	}
	addInt(q, "limit", p.Limit)
	if len(p.Types) > 0 {
		q["types"] = p.Types
	}
	var r EventPage
	if err := e.h.Request(ctx, "GET", "/api/v1/events", &RequestOptions{Query: q}, &r); err != nil {
		return nil, err
	}
	return &r, nil
}

// List returns one page of the event feed, in order. Pass the returned Next as After for the following page.
func (e *Events) List(ctx context.Context, p ListEventsParams) (*EventPage, error) {
	return e.page(ctx, p, false)
}

// Iterate yields every event after p.After, page by page, until the feed is caught up. Remember the
// last ID to resume. A request error is yielded once, and ends the iteration.
//
//	for ev, err := range client.Events.Iterate(ctx, callio.ListEventsParams{After: last}) { ... }
func (e *Events) Iterate(ctx context.Context, p ListEventsParams) iter.Seq2[Event, error] {
	return func(yield func(Event, error) bool) {
		after := p.After
		for {
			q := p
			q.After = after
			pg, err := e.page(ctx, q, true)
			if err != nil {
				yield(Event{}, err)
				return
			}
			for _, ev := range pg.Events {
				if !yield(ev, nil) {
					return
				}
			}
			if len(pg.Events) == 0 || pg.Next <= after {
				return
			}
			after = pg.Next
		}
	}
}

// CDR reads call records.
type CDR struct{ h *HTTPClient }

// List returns call records for the last Days (1–90, default 7): one row per call.
func (c *CDR) List(ctx context.Context, p ListCdrParams) (*CdrPage, error) {
	q := Query{}
	addInt(q, "days", p.Days)
	addStr(q, "type", string(p.Type))
	var r CdrPage
	if err := c.h.Request(ctx, "GET", "/api/v1/cdr", &RequestOptions{Query: q}, &r); err != nil {
		return nil, err
	}
	return &r, nil
}
