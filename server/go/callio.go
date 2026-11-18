// Package callio is the Callio server SDK for Go: the tenant REST API (users, app tokens, orders,
// recordings, groups, events, CDR) and webhook verification, on the standard library.
//
// Keep the client on your server: the API key gives full access to your organisation's users, orders
// and recordings.
//
//	client, err := callio.New(callio.WithAPIKey(os.Getenv("CALLIO_API_KEY")), callio.WithBaseURL("https://api.example.sa"))
//	t, err := client.Tokens.ForUser(ctx, "cust-42", callio.ForUserOptions{DisplayName: "Sara", UserType: callio.UserTypeCustomer})
package callio

import (
	"fmt"
	"net/http"
	"os"
	"regexp"
	"runtime"
	"strings"
	"time"
)

// Client is the Callio tenant API client.
type Client struct {
	Users      *Users
	Tokens     *Tokens
	Orders     *Orders
	Recordings *Recordings
	Groups     *Groups
	Events     *Events
	CDR        *CDR
	// HTTP is the underlying client (Request / RequestRaw for endpoints the SDK doesn't wrap yet).
	HTTP *HTTPClient
}

// Option configures New.
type Option func(*config)

type config struct {
	apiKey, baseURL, userAgent string
	timeout                    time.Duration
	maxRetries                 int
	allowInsecure              bool
	httpClient                 *http.Client
}

// WithAPIKey sets the tenant API key, cio_<id>_<secret>. Defaults to the CALLIO_API_KEY environment variable.
func WithAPIKey(key string) Option { return func(c *config) { c.apiKey = key } }

// WithBaseURL sets your Callio host, e.g. https://api.example.sa. Defaults to CALLIO_BASE_URL.
func WithBaseURL(u string) Option { return func(c *config) { c.baseURL = u } }

// WithTimeout sets the per-attempt timeout (default 30 s).
func WithTimeout(d time.Duration) Option { return func(c *config) { c.timeout = d } }

// WithMaxRetries sets the retries for idempotent requests on 429 / 5xx / network errors (default 2).
func WithMaxRetries(n int) Option { return func(c *config) { c.maxRetries = max(0, n) } }

// WithHTTPClient replaces the *http.Client (proxies, tests, instrumentation). Its Timeout should be 0:
// the SDK applies its own per-attempt timeout.
func WithHTTPClient(hc *http.Client) Option { return func(c *config) { c.httpClient = hc } }

// WithAllowInsecure permits an http:// base URL. Only for a local development stack: over plain HTTP
// the API key travels in clear text.
func WithAllowInsecure(allow bool) Option { return func(c *config) { c.allowInsecure = allow } }

// WithUserAgent appends to the User-Agent, e.g. "my-backend/1.4".
func WithUserAgent(ua string) Option { return func(c *config) { c.userAgent = ua } }

var (
	httpsRE = regexp.MustCompile(`(?i)^https://[^/]`)
	httpRE  = regexp.MustCompile(`(?i)^http://[^/]`)
)

// refuseRedirect makes net/http hand back the 3xx response instead of following it.
func refuseRedirect(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }

// New creates a client. It returns an error when the key or base URL is missing or invalid.
func New(opts ...Option) (*Client, error) {
	cfg := config{timeout: 30 * time.Second, maxRetries: 2}
	for _, o := range opts {
		o(&cfg)
	}
	if cfg.apiKey == "" {
		cfg.apiKey = os.Getenv("CALLIO_API_KEY")
	}
	if cfg.baseURL == "" {
		cfg.baseURL = os.Getenv("CALLIO_BASE_URL")
	}
	if cfg.apiKey == "" {
		return nil, &Error{Message: "callio: apiKey is required (or set CALLIO_API_KEY)"}
	}
	if cfg.baseURL == "" {
		return nil, &Error{Message: "callio: baseURL is required (or set CALLIO_BASE_URL), e.g. https://api.example.sa"}
	}
	if !httpsRE.MatchString(cfg.baseURL) && !(cfg.allowInsecure && httpRE.MatchString(cfg.baseURL)) {
		return nil, &Error{Message: "callio: baseURL must start with https:// (http:// only with WithAllowInsecure(true), for a local stack)"}
	}
	// Never follow redirects, also on a caller-supplied client (copied, not modified).
	hc := &http.Client{}
	if cfg.httpClient != nil {
		c := *cfg.httpClient
		hc = &c
	}
	hc.CheckRedirect = refuseRedirect
	ua := fmt.Sprintf("callio-server-go/%s go/%s", Version, strings.TrimPrefix(runtime.Version(), "go"))
	if cfg.userAgent != "" {
		ua += " " + cfg.userAgent
	}
	h := &HTTPClient{
		BaseURL:    strings.TrimRight(cfg.baseURL, "/"),
		Timeout:    cfg.timeout,
		MaxRetries: cfg.maxRetries,
		UserAgent:  ua,
		Backoff:    defaultBackoff,
		key:        &secret{v: cfg.apiKey},
		client:     hc,
	}
	users := &Users{h: h}
	return &Client{
		Users:      users,
		Tokens:     &Tokens{h: h, users: users},
		Orders:     &Orders{h: h},
		Recordings: &Recordings{h: h},
		Groups:     &Groups{h: h},
		Events:     &Events{h: h},
		CDR:        &CDR{h: h},
		HTTP:       h,
	}, nil
}

// String never includes the key.
func (c *Client) String() string { return fmt.Sprintf("callio.Client{BaseURL: %q}", c.HTTP.BaseURL) }

// GoString never includes the key.
func (c *Client) GoString() string { return c.String() }
