package callio

// Integration test against a running Callio stack. It signs in to the admin API, creates a temporary API
// key for the tenant, exercises the SDK, and cleans up everything it made (users, order, group, the key).
// Nothing secret lives in this file; pass it in the environment:
//
//	CALLIO_ADMIN_PASS=… [CALLIO_ADMIN_USER=admin] [CALLIO_URL=http://localhost:8080] [CALLIO_TENANT=lab] \
//	  go test -run TestIntegration -v ./...
//
// CALLIO_IT_AUDIO=1 also downloads one recording (that read is written to the recording's access trail).
// Skipped when CALLIO_ADMIN_PASS is not set.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func adminReq(t *testing.T, base, token, method, path string, body any) map[string]any {
	t.Helper()
	var rdr *bytes.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rdr = bytes.NewReader(b)
	} else {
		rdr = bytes.NewReader(nil)
	}
	req, _ := http.NewRequest(method, base+path, rdr)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := (&http.Client{Timeout: 15 * time.Second}).Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if resp.StatusCode >= 300 {
		t.Fatalf("%s %s → %d %v", method, path, resp.StatusCode, out["error"])
	}
	return out
}

func TestIntegration(t *testing.T) {
	pass := os.Getenv("CALLIO_ADMIN_PASS")
	if pass == "" {
		t.Skip("set CALLIO_ADMIN_PASS (and optionally CALLIO_ADMIN_USER, CALLIO_URL, CALLIO_TENANT)")
	}
	base := strings.TrimRight(envOr("CALLIO_URL", "http://localhost:8080"), "/")
	tenant := envOr("CALLIO_TENANT", "lab")
	run := strconv.FormatInt(time.Now().UnixMilli(), 36)
	cust, agent, order, group := "sdk-it-go-c-"+run, "sdk-it-go-a-"+run, "SDK-IT-GO-"+run, "sdk-it-go-g-"+run

	admin, _ := adminReq(t, base, "", "POST", "/api/admin/login", map[string]string{"username": envOr("CALLIO_ADMIN_USER", "admin"), "password": pass})["token"].(string)
	if admin == "" {
		t.Fatal("admin login (MFA-enabled admins are not supported by this test)")
	}
	key := adminReq(t, base, admin, "POST", "/api/admin/tenants/"+tenant+"/api-keys", map[string]string{"name": "sdk-it-go-" + run})["key"].(map[string]any)
	c, err := New(WithAPIKey(key["key"].(string)), WithBaseURL(base), WithAllowInsecure(strings.HasPrefix(base, "http://")), WithUserAgent("callio-it"))
	if err != nil {
		t.Fatal(err)
	}
	var users []string
	groupMade, orderMade := false, false
	t.Cleanup(func() {
		if groupMade {
			_, _ = c.Groups.Delete(ctx, group)
		}
		if orderMade {
			_, _ = c.Orders.Close(ctx, order) // orders can't be deleted; erasing the users pseudonymises it
		}
		for _, u := range users {
			_, _ = c.Users.Delete(ctx, u, "SDK integration test cleanup")
		}
		adminReq(t, base, admin, "DELETE", "/api/admin/tenants/"+tenant+"/api-keys/"+key["id"].(string), nil)
		if _, err := c.Users.List(ctx, ListUsersParams{Limit: 1}); !errors.Is(err, ErrAuthentication) {
			t.Errorf("the revoked key still works: %v", err)
		}
	})
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	is := func(err, kind error) {
		t.Helper()
		if !errors.Is(err, kind) {
			t.Fatalf("want %v, got %v", kind, err)
		}
	}

	t.Run("users", func(t *testing.T) {
		u, err := c.Users.Create(ctx, CreateUserParams{Username: cust, DisplayName: "SDK IT Customer", UserType: UserTypeCustomer})
		must(err)
		users = append(users, cust)
		if u.Username != cust || u.UserType != UserTypeCustomer || u.Extension == "" || u.InitialPassword == "" {
			t.Fatalf("%+v", u)
		}
		_, err = c.Users.Create(ctx, CreateUserParams{Username: cust})
		is(err, ErrConflict)
		_, err = c.Users.Create(ctx, CreateUserParams{Username: "bad name!"})
		is(err, ErrValidation)
		_, err = c.Users.Get(ctx, cust+"-missing")
		is(err, ErrNotFound)
		g, err := c.Users.Get(ctx, cust)
		must(err)
		if *g.DisplayName != "SDK IT Customer" {
			t.Fatal(*g.DisplayName)
		}
		up, err := c.Users.Update(ctx, cust, UpdateUserParams{DisplayName: "SDK IT Renamed", Segment: Set("sdk-it")})
		must(err)
		if *up.DisplayName != "SDK IT Renamed" || *up.Segment != "sdk-it" {
			t.Fatalf("%+v", up)
		}
		list, err := c.Users.List(ctx, ListUsersParams{Q: cust})
		must(err)
		if !slices.ContainsFunc(list, func(x User) bool { return x.Username == cust }) {
			t.Fatal("not listed")
		}
		tok, err := c.Tokens.Create(ctx, CreateTokenParams{Username: cust, TTLSec: 120})
		must(err)
		exp, perr := time.Parse(time.RFC3339, tok.ExpiresAt)
		if len(strings.Split(tok.Token, ".")) != 3 || tok.UserType != UserTypeCustomer || perr != nil || !exp.After(time.Now()) {
			t.Fatalf("%+v %v", tok, perr)
		}
		ok, err := c.Users.SignOut(ctx, cust)
		must(err)
		if !ok.OK {
			t.Fatal("sign-out")
		}
		ex, err := c.Users.Export(ctx, cust)
		must(err)
		if ex["exportedAt"] == nil {
			t.Fatal("export")
		}
	})

	t.Run("tokens.ForUser", func(t *testing.T) {
		first, err := c.Tokens.ForUser(ctx, agent, ForUserOptions{DisplayName: "SDK IT Agent", UserType: UserTypeAgent, TTLSec: 60})
		must(err)
		users = append(users, agent)
		if !first.Created || first.UserType != UserTypeAgent {
			t.Fatalf("%+v", first)
		}
		again, err := c.Tokens.ForUser(ctx, agent, ForUserOptions{UserType: UserTypeAgent})
		must(err)
		if again.Created || again.Token == "" {
			t.Fatalf("%+v", again)
		}
		_, err = c.Users.Disable(ctx, agent)
		must(err)
		_, err = c.Tokens.Create(ctx, CreateTokenParams{Username: agent})
		var ce *Error
		if !errors.As(err, &ce) || ce.Status != 403 {
			t.Fatal(err)
		}
		_, err = c.Users.Enable(ctx, agent)
		must(err)
	})

	t.Run("orders and events", func(t *testing.T) {
		pg, err := c.Events.List(ctx, ListEventsParams{Limit: 1})
		must(err)
		before := pg.Next
		_, err = c.Orders.Create(ctx, CreateOrderParams{ID: order, Customer: agent}) // wrong user type
		is(err, ErrValidation)
		o, err := c.Orders.Create(ctx, CreateOrderParams{ID: order, Customer: cust, Label: "SDK integration test"})
		must(err)
		orderMade = true
		if o.Status != OrderActive || o.Agent != nil {
			t.Fatalf("%+v", o)
		}
		_, err = c.Orders.Create(ctx, CreateOrderParams{ID: order, Customer: cust})
		is(err, ErrConflict)
		g, err := c.Orders.Get(ctx, order)
		must(err)
		if *g.Label != "SDK integration test" {
			t.Fatal(*g.Label)
		}
		list, err := c.Orders.List(ctx, ListOrdersParams{User: cust})
		must(err)
		if !slices.ContainsFunc(list, func(x Order) bool { return x.ID == order }) {
			t.Fatal("not listed")
		}
		a, err := c.Orders.Assign(ctx, order, agent)
		must(err)
		if a.Agent == nil || *a.Agent != agent {
			t.Fatalf("%+v", a)
		}
		for _, step := range []struct {
			f    func() (*Order, error)
			want OrderStatus
		}{
			{func() (*Order, error) { return c.Orders.Close(ctx, order) }, OrderClosed},
			{func() (*Order, error) { return c.Orders.Reopen(ctx, order) }, OrderActive},
			{func() (*Order, error) { return c.Orders.Update(ctx, order, UpdateOrderParams{Status: OrderClosed}) }, OrderClosed},
		} {
			r, err := step.f()
			must(err)
			if r.Status != step.want {
				t.Fatalf("%s != %s", r.Status, step.want)
			}
		}
		_, err = c.Orders.Get(ctx, order+"-nope")
		is(err, ErrNotFound)

		var seen []string
		for e, err := range c.Events.Iterate(ctx, ListEventsParams{After: max(0, before-1), Types: []string{"order."}, Limit: 100}) {
			must(err)
			if e.OrderID != nil && *e.OrderID == order {
				seen = append(seen, e.Type)
			}
		}
		for _, ty := range []string{"order.created", "order.assigned", "order.closed", "order.reopened"} {
			if !slices.Contains(seen, ty) {
				t.Fatalf("%s not in %v", ty, seen)
			}
		}
	})

	t.Run("groups", func(t *testing.T) {
		g, err := c.Groups.Create(ctx, CreateGroupParams{ID: group, Name: "SDK IT group", Members: []string{cust, agent}})
		must(err)
		groupMade = true
		if len(g.Members) != 2 {
			t.Fatalf("%+v", g)
		}
		gg, err := c.Groups.Get(ctx, group)
		must(err)
		if gg.Name != "SDK IT group" {
			t.Fatal(gg.Name)
		}
		u, err := c.Groups.Update(ctx, group, UpdateGroupParams{Name: "SDK IT renamed", Remove: []string{agent}})
		must(err)
		if u.Name != "SDK IT renamed" || len(u.Members) != 1 || u.Members[0].Username != cust {
			t.Fatalf("%+v", u)
		}
		list, err := c.Groups.List(ctx)
		must(err)
		if !slices.ContainsFunc(list, func(x Group) bool { return x.ID == group }) {
			t.Fatal("not listed")
		}
		ok, err := c.Groups.Delete(ctx, group)
		must(err)
		if !ok.OK {
			t.Fatal("delete")
		}
		groupMade = false
		_, err = c.Groups.Get(ctx, group)
		is(err, ErrNotFound)
	})

	t.Run("recordings and cdr", func(t *testing.T) {
		recs, err := c.Recordings.List(ctx, ListRecordingsParams{Limit: 5})
		must(err)
		if len(recs) > 0 {
			r, err := c.Recordings.Get(ctx, recs[0].ID)
			must(err)
			if r.ID != recs[0].ID {
				t.Fatal(r.ID)
			}
			if os.Getenv("CALLIO_IT_AUDIO") == "1" {
				var buf bytes.Buffer
				n, err := c.Recordings.DownloadTo(ctx, recs[0].ID, &buf, "SDK integration test")
				must(err)
				if n != recs[0].Bytes || !bytes.HasPrefix(buf.Bytes(), []byte("OggS")) {
					t.Fatalf("%d bytes", n)
				}
			}
		}
		_, err = c.Recordings.Get(ctx, "no-such-recording")
		is(err, ErrNotFound)
		_, err = c.Recordings.Audio(ctx, "no-such-recording", "SDK integration test")
		is(err, ErrNotFound)
		cdr, err := c.CDR.List(ctx, ListCdrParams{Days: 30})
		must(err)
		if cdr.Days != 30 || cdr.Calls == nil {
			t.Fatalf("%+v", cdr)
		}
	})

	t.Run("users.Delete (PDPL erasure)", func(t *testing.T) {
		r, err := c.Users.Delete(ctx, agent, "SDK integration test cleanup")
		must(err)
		if !r.OK || !strings.HasPrefix(r.Alias, "erased-") {
			t.Fatalf("%+v", r)
		}
		users = slices.DeleteFunc(users, func(u string) bool { return u == agent })
		_, err = c.Users.Get(ctx, agent)
		is(err, ErrNotFound)
	})
	_ = fmt.Sprint
}
