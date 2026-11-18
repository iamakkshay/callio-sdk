package callio

// Models returned by the Callio tenant API (/api/v1). JSON field names match the wire. Timestamps are ISO
// 8601 strings, as the API sends them; nullable fields are pointers.

import (
	"encoding/json"
	"time"
)

// UserType is a user's role.
type UserType string

const (
	UserTypeCustomer UserType = "customer"
	UserTypeAgent    UserType = "agent"
	UserTypeGuest    UserType = "guest"
)

// OrderStatus is an order's state.
type OrderStatus string

const (
	OrderActive OrderStatus = "active"
	OrderClosed OrderStatus = "closed"
)

// Nullable is a PATCH field with three states: unset (the zero value, left unchanged), Set(v), or
// Null (cleared on the server).
type Nullable[T any] struct {
	v         T
	set, null bool
}

// Set returns a Nullable holding v.
func Set[T any](v T) Nullable[T] { return Nullable[T]{v: v, set: true} }

// Null returns a Nullable that clears the field.
func Null[T any]() Nullable[T] { return Nullable[T]{set: true, null: true} }

// IsSet reports whether the field will be sent.
func (n Nullable[T]) IsSet() bool { return n.set }

func (n Nullable[T]) put(m map[string]any, k string) {
	if !n.set {
		return
	}
	if n.null {
		m[k] = nil
	} else {
		m[k] = n.v
	}
}

// Ptr returns a pointer to v (for optional fields such as UpdateUserParams.Disabled).
func Ptr[T any](v T) *T { return &v }

// User is a Callio user.
type User struct {
	Username    string   `json:"username"`
	DisplayName *string  `json:"displayName"`
	UserType    UserType `json:"userType"`
	// Extension is the user's SIP extension.
	Extension string  `json:"extension"`
	Segment   *string `json:"segment"`
	Disabled  bool    `json:"disabled"`
	// Phone is the masked phone fallback number (only on get/create/update, not in list results).
	Phone *string `json:"phone,omitempty"`
}

// CreatedUser is the result of Users.Create.
type CreatedUser struct {
	User
	// InitialPassword is returned once, when the user was created without a LoginPassword.
	InitialPassword string `json:"initialPassword,omitempty"`
}

// ListUsersParams filters Users.List. Zero values are left out.
type ListUsersParams struct {
	Q       string
	Type    UserType
	Status  string // active | disabled
	Segment string
	Limit   int
}

// CreateUserParams is the body of Users.Create.
type CreateUserParams struct {
	Username      string   `json:"username"`
	DisplayName   string   `json:"displayName,omitempty"`
	UserType      UserType `json:"userType,omitempty"`
	LoginPassword string   `json:"loginPassword,omitempty"`
	Phone         string   `json:"phone,omitempty"`
}

// UpdateUserParams is the body of Users.Update. Zero values are left unchanged.
type UpdateUserParams struct {
	DisplayName string
	UserType    UserType
	Disabled    *bool
	Segment     Nullable[string]
	Phone       Nullable[string]
}

// MarshalJSON sends only the fields that are set.
func (p UpdateUserParams) MarshalJSON() ([]byte, error) {
	m := map[string]any{}
	if p.DisplayName != "" {
		m["displayName"] = p.DisplayName
	}
	if p.UserType != "" {
		m["userType"] = p.UserType
	}
	if p.Disabled != nil {
		m["disabled"] = *p.Disabled
	}
	p.Segment.put(m, "segment")
	p.Phone.put(m, "phone")
	return json.Marshal(m)
}

// ErasureResult is the result of Users.Delete (PDPL erasure).
type ErasureResult struct {
	OK bool `json:"ok"`
	// Alias is the pseudonym that replaced the user in records that are kept.
	Alias                     string         `json:"alias"`
	Removed                   map[string]int `json:"removed"`
	RecordingsKeptOnLegalHold []string       `json:"recordingsKeptOnLegalHold"`
}

// UserExport is the PDPL access-request export: everything held about a user. The shape is the
// platform's and may grow; exportedAt and tenant are always present.
type UserExport map[string]any

// Token is a short-lived app token.
type Token struct {
	// Token is a JWT for the app SDKs.
	Token     string   `json:"token"`
	UserType  UserType `json:"userType"`
	ExpiresAt string   `json:"expiresAt"`
}

// CreateTokenParams is the body of Tokens.Create.
type CreateTokenParams struct {
	Username string `json:"username"`
	// TTLSec is 60–3600 (default 900 when 0).
	TTLSec int `json:"ttlSec,omitempty"`
	// DeviceID is the app's device id (its X-Device-Id): the token works on that device only. Empty: on the first
	// device that uses it.
	DeviceID string `json:"deviceId,omitempty"`
}

// ForUserOptions configures Tokens.ForUser.
type ForUserOptions struct {
	DisplayName string
	UserType    UserType
	TTLSec      int
	Phone       string
	DeviceID    string
}

// UserToken is the result of Tokens.ForUser.
type UserToken struct {
	Token     string   `json:"token"`
	UserType  UserType `json:"userType"`
	ExpiresAt string   `json:"expiresAt"`
	// Created is true when ForUser created the user on this call.
	Created bool `json:"created"`
}

// Order links a customer and (optionally) an agent.
type Order struct {
	ID        string      `json:"id"`
	Customer  string      `json:"customer"`
	Agent     *string     `json:"agent"`
	Status    OrderStatus `json:"status"`
	Label     *string     `json:"label"`
	CreatedAt string      `json:"createdAt"`
	UpdatedAt string      `json:"updatedAt"`
	ClosedAt  *string     `json:"closedAt"`
}

// CreateOrderParams is the body of Orders.Create.
type CreateOrderParams struct {
	ID       string `json:"id"`
	Customer string `json:"customer"`
	Agent    string `json:"agent,omitempty"`
	Label    string `json:"label,omitempty"`
}

// UpdateOrderParams is the body of Orders.Update. Unset fields are left unchanged.
type UpdateOrderParams struct {
	// Agent: Set("drv-7") reassigns, Null[string]() unassigns.
	Agent  Nullable[string]
	Status OrderStatus
	Label  Nullable[string]
}

// MarshalJSON sends only the fields that are set.
func (p UpdateOrderParams) MarshalJSON() ([]byte, error) {
	m := map[string]any{}
	p.Agent.put(m, "agent")
	if p.Status != "" {
		m["status"] = p.Status
	}
	p.Label.put(m, "label")
	return json.Marshal(m)
}

// ListOrdersParams filters Orders.List.
type ListOrdersParams struct {
	Status OrderStatus
	User   string
	Limit  int
}

// TranscriptStatus is a recording's transcript state.
type TranscriptStatus struct {
	Status   string  `json:"status"`
	Language *string `json:"language"`
	Error    *string `json:"error"`
}

// Recording is a call recording's metadata.
type Recording struct {
	ID           string            `json:"id"`
	Tenant       string            `json:"tenant"`
	CallRef      *string           `json:"callRef"`
	Caller       *string           `json:"caller"`
	Callee       *string           `json:"callee"`
	CallType     *string           `json:"callType"`
	OrderID      *string           `json:"orderId"`
	StartedAt    *string           `json:"startedAt"`
	DurationSec  float64           `json:"durationSec"`
	Bytes        int64             `json:"bytes"`
	Format       *string           `json:"format"`
	Status       string            `json:"status"` // stored | deleted
	LegalHold    bool              `json:"legalHold"`
	HoldReason   *string           `json:"holdReason"`
	RetainUntil  *string           `json:"retainUntil"`
	DeletedAt    *string           `json:"deletedAt"`
	DeleteReason *string           `json:"deleteReason"`
	CreatedAt    string            `json:"createdAt"`
	Transcript   *TranscriptStatus `json:"transcript"`
}

// ListRecordingsParams filters Recordings.List. Zero values are left out.
type ListRecordingsParams struct {
	// From and To are sent as ISO 8601 (UTC).
	From, To time.Time
	// User is either party's extension.
	User        string
	CallID      string
	OrderID     string
	MinDuration int
	MaxDuration int
	Status      string // stored (default) | deleted | all
	Limit       int
}

// TranscriptSegment is one timed piece of a transcript.
type TranscriptSegment struct {
	Start float64 `json:"start"`
	End   float64 `json:"end"`
	Text  string  `json:"text"`
}

// Transcript is a recording's transcript.
type Transcript struct {
	Text     string              `json:"text"`
	Language *string             `json:"language"`
	Segments []TranscriptSegment `json:"segments"`
}

// GroupMember is a member of a group chat.
type GroupMember struct {
	Username    string  `json:"username"`
	DisplayName *string `json:"displayName"`
	UserType    string  `json:"userType"`
	SipUser     string  `json:"sipUser"`
}

// Group is a group chat.
type Group struct {
	ID        string        `json:"id"`
	Name      string        `json:"name"`
	CreatedAt string        `json:"createdAt"`
	Members   []GroupMember `json:"members"`
}

// CreateGroupParams is the body of Groups.Create.
type CreateGroupParams struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// Members are 2–50 usernames.
	Members []string `json:"members"`
}

// UpdateGroupParams is the body of Groups.Update.
type UpdateGroupParams struct {
	Name   string   `json:"name,omitempty"`
	Add    []string `json:"add,omitempty"`
	Remove []string `json:"remove,omitempty"`
}

// Event is one entry of the event feed.
type Event struct {
	ID       int64          `json:"id"`
	Type     string         `json:"type"`
	CallID   *string        `json:"callId"`
	From     *string        `json:"from"`
	To       *string        `json:"to"`
	FromType *string        `json:"fromType"`
	ToType   *string        `json:"toType"`
	OrderID  *string        `json:"orderId"`
	At       string         `json:"at"`
	Payload  map[string]any `json:"payload"`
}

// ListEventsParams filters Events.List and Events.Iterate.
type ListEventsParams struct {
	After int64
	Limit int
	// Types are type prefixes, e.g. []string{"call.", "chat."}.
	Types []string
}

// EventPage is one page of the event feed. Pass Next as After for the following page.
type EventPage struct {
	Events []Event `json:"events"`
	Next   int64   `json:"next"`
}

// CallRecord is one row of the call records.
type CallRecord struct {
	CallID      string          `json:"callId"`
	Tenant      string          `json:"tenant"`
	From        *string         `json:"from"`
	To          *string         `json:"to"`
	FromType    *string         `json:"fromType"`
	ToType      *string         `json:"toType"`
	Direction   string          `json:"direction"`
	Support     bool            `json:"support"`
	OrderID     *string         `json:"orderId"`
	EntryPoint  *string         `json:"entryPoint"`
	Outcome     string          `json:"outcome"`
	EndReason   string          `json:"endReason"`
	DurationSec float64         `json:"durationSec"`
	AnswerSec   *float64        `json:"answerSec"`
	StartedAt   *string         `json:"startedAt"`
	AnsweredAt  *string         `json:"answeredAt"`
	EndedAt     *string         `json:"endedAt"`
	Quality     json.RawMessage `json:"quality"`
	Client      json.RawMessage `json:"client"`
}

// ListCdrParams filters CDR.List.
type ListCdrParams struct {
	// Days is 1–90 (default 7 when 0).
	Days int
	Type UserType
}

// CdrPage is the result of CDR.List.
type CdrPage struct {
	Days  int          `json:"days"`
	Calls []CallRecord `json:"calls"`
}

// OK is the result of endpoints that only acknowledge.
type OK struct {
	OK bool `json:"ok"`
}
