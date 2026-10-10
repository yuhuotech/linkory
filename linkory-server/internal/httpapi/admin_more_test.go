package httpapi

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAdminAccountRecoveryAndSessions(t *testing.T) {
	s, h := setupAdmin(t)
	ctx := context.Background()
	if e := s.CreateAccount(ctx, "owner", "admin-test-password-123", "admin"); e == nil {
		t.Fatal("duplicate admin name accepted")
	}
	if e := s.CreateAccount(ctx, "short", "tooshort", "admin"); e == nil {
		t.Fatal("short password accepted")
	}
	if e := s.CreateAccount(ctx, "weird", "admin-test-password-123", "root"); e == nil {
		t.Fatal("unknown role accepted")
	}
	owner := managementLogin(t, h, "owner")

	// Forgotten password: the CLI reset replaces it and ends every session.
	if e := s.ResetPassword(ctx, "owner", "short"); e == nil {
		t.Fatal("short reset password accepted")
	}
	if e := s.ResetPassword(ctx, "nobody", "a-brand-new-password-1"); e == nil {
		t.Fatal("reset of unknown admin succeeded")
	}
	if e := s.ResetPassword(ctx, "owner", "a-brand-new-password-1"); e != nil {
		t.Fatal(e)
	}
	if code, _ := owner.request("GET", "overview", nil); code != 401 {
		t.Fatal("session survived password reset", code)
	}
	fresh := &adminClient{h: h}
	if code, _ := fresh.request("POST", "auth/login", map[string]any{"username": "owner", "password": "admin-test-password-123"}); code != 401 {
		t.Fatal("old password still works", code)
	}
	if code, _ := fresh.request("POST", "auth/login", map[string]any{"username": "owner", "password": "a-brand-new-password-1"}); code != 200 {
		t.Fatal("new password rejected", code)
	}

	accounts, e := s.ListAccounts(ctx)
	if e != nil || len(accounts) != 2 || accounts[0].Username != "owner" || accounts[1].Role != "readonly" {
		t.Fatal("list", accounts, e)
	}

	// Disabling ends the session at once and blocks new logins; the account remains listed.
	if e := s.DisableAccount(ctx, "owner"); e != nil {
		t.Fatal(e)
	}
	if e := s.DisableAccount(ctx, "owner"); e == nil {
		t.Fatal("disabling twice should report not found")
	}
	if code, _ := fresh.request("GET", "overview", nil); code != 401 {
		t.Fatal("disabled admin session alive", code)
	}
	again := &adminClient{h: h}
	if code, _ := again.request("POST", "auth/login", map[string]any{"username": "owner", "password": "a-brand-new-password-1"}); code != 401 {
		t.Fatal("disabled admin logged in", code)
	}
	if accounts, _ = s.ListAccounts(ctx); !accounts[0].Disabled {
		t.Fatal("disabled flag missing")
	}

	// An expired session is rejected even though the cookie is still sent; logout kills the session.
	viewer := managementLogin(t, h, "viewer")
	if _, e := s.DB.Exec(`UPDATE admin_sessions SET expires_at=UTC_TIMESTAMP(3)-INTERVAL 1 SECOND`); e != nil {
		t.Fatal(e)
	}
	if code, _ := viewer.request("GET", "overview", nil); code != 401 {
		t.Fatal("expired session accepted", code)
	}
	viewer = managementLogin(t, h, "viewer")
	if code, _ := viewer.request("POST", "auth/logout", nil); code != 204 {
		t.Fatal("logout", code)
	}
	if code, _ := viewer.request("GET", "overview", nil); code != 401 {
		t.Fatal("session survived logout", code)
	}
}

func TestAdminLoginGuards(t *testing.T) {
	_, h := setupAdmin(t)
	post := func(origin, marker string) int {
		r := httptest.NewRequest("POST", "http://admin.test/api/admin/v1/auth/login", strings.NewReader(`{"username":"owner","password":"nope-nope-nope"}`))
		if origin != "" {
			r.Header.Set("Origin", origin)
		}
		if marker != "" {
			r.Header.Set("X-Linkory-Admin", marker)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w.Code
	}
	if c := post("http://evil.test", "1"); c != 403 {
		t.Fatal("cross-origin login", c)
	}
	if c := post("", "1"); c != 403 {
		t.Fatal("login without Origin", c)
	}
	if c := post("http://admin.test", ""); c != 403 {
		t.Fatal("login without marker header", c)
	}
	for i := 0; i < 5; i++ {
		if c := post("http://admin.test", "1"); c != 401 {
			t.Fatalf("attempt %d: %d", i, c)
		}
	}
	if c := post("http://admin.test", "1"); c != 429 {
		t.Fatal("brute force not limited", c)
	}
}

func TestAdminReadonlyAuditAndQueries(t *testing.T) {
	s, h := setupAdmin(t)
	owner := managementLogin(t, h, "owner")
	viewer := managementLogin(t, h, "viewer")
	call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": "alice", "password": "password123"})
	call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": "bobby", "password": "password123"})
	a := login(t, h, "alice", "Alice Mac")
	login(t, h, "bobby", "Bob Phone")
	uid := fmt.Sprint(a["user_id"])

	// Every write is refused for readonly and leaves a denial in the audit trail.
	for _, w := range []struct{ method, path string }{
		{"POST", "users/" + uid + "/revoke"}, {"POST", "devices/" + fmt.Sprint(a["device_id"]) + "/remove"},
		{"POST", "retention/preview"}, {"PUT", "retention"}, {"POST", "jobs"},
	} {
		if code, _ := viewer.request(w.method, w.path, map[string]any{"reason": "只读写入测试"}); code != 403 {
			t.Fatalf("readonly %s %s: %d", w.method, w.path, code)
		}
	}
	code, out := owner.request("GET", "audit?action=access.denied", nil)
	if code != 200 || out["total"].(float64) < 5 {
		t.Fatal("denials not audited", code, out["total"])
	}
	if code, out = owner.request("GET", "audit?action=auth.login&actor=viewer", nil); code != 200 || out["total"].(float64) != 1 {
		t.Fatal("audit filter", code, out["total"])
	}

	// Filters and bounds.
	count := func(path string) float64 {
		code, out := owner.request("GET", path, nil)
		if code != 200 {
			t.Fatalf("%s: %d", path, code)
		}
		return out["total"].(float64)
	}
	if count("users") != 2 || count("users?q=alic") != 1 || count("users?q="+uid) != 1 || count("users?status=disabled") != 0 || count("users?status=active") != 2 {
		t.Fatal("user filters")
	}
	if count("devices") != 2 || count("devices?q=Bob") != 1 || count("devices?user_id="+uid) != 1 || count("devices?status=revoked") != 0 {
		t.Fatal("device filters")
	}
	if _, e := s.DB.Exec(`UPDATE devices SET status='offline'`); e != nil {
		t.Fatal(e)
	}
	if count("devices?status=offline") != 2 || count("devices?status=online") != 0 {
		t.Fatal("device status filters")
	}
	if code, _ := owner.request("GET", "transfers?from=yesterday", nil); code != 400 {
		t.Fatal("bad date accepted", code)
	}
	if code, _ := owner.request("GET", "users/999999", nil); code != 404 {
		t.Fatal("missing user", code)
	}
	if code, _ := owner.request("GET", "devices/nope", nil); code != 404 {
		t.Fatal("missing device", code)
	}
	if code, _ := owner.request("GET", "transfers/nope", nil); code != 404 {
		t.Fatal("missing transfer", code)
	}
	if code, _ := owner.request("POST", "users/"+uid+"/explode", map[string]any{"reason": "未知动作测试"}); code != 404 {
		t.Fatal("unknown action", code)
	}
	if code, _ := owner.request("POST", "users/"+uid+"/disable", map[string]any{"reason": "x"}); code != 400 {
		t.Fatal("one-character reason accepted", code)
	}
	if code, out = owner.request("GET", "users?page_size=100000&page=-3", nil); code != 200 || out["page_size"].(float64) != 20 || out["page"].(float64) != 1 {
		t.Fatal("pagination not clamped", out)
	}

	code, out = owner.request("GET", "overview", nil)
	if code != 200 || out["users"].(float64) != 2 || out["devices"].(float64) != 2 || out["database_healthy"] != true || len(out["trend"].([]any)) != 7 {
		t.Fatal("overview", code, out)
	}
	if code, _ = owner.request("PUT", "retention", map[string]any{"offline_days": 0, "delivered_days": 0, "transfer_days": 0, "reason": "非法天数"}); code != 400 {
		t.Fatal("offline_days=0 accepted", code)
	}
	if code, out = owner.request("PUT", "retention", map[string]any{"offline_days": 7, "delivered_days": 90, "transfer_days": 60, "reason": "调整保留策略"}); code != 200 || out["offline_days"].(float64) != 7 {
		t.Fatal("policy update", code, out)
	}
	if code, out = viewer.request("GET", "retention", nil); code != 200 || out["delivered_days"].(float64) != 90 {
		t.Fatal("policy not persisted", out)
	}
}

func TestAdminRetentionWorker(t *testing.T) {
	s, h := setupAdmin(t)
	owner := managementLogin(t, h, "owner")
	call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": "alice", "password": "password123"})
	a := login(t, h, "alice", "one")
	b := login(t, h, "alice", "two")
	uid, from, to := fmt.Sprint(a["user_id"]), a["device_id"].(string), b["device_id"].(string)
	ctx := context.Background()
	if _, e := s.DB.Exec(`INSERT INTO conversations(id,user_id,device_lo,device_hi) VALUES('conv',?,?,?)`, uid, from, to); e != nil {
		t.Fatal(e)
	}
	old := time.Now().UTC().AddDate(0, 0, -50)
	for _, m := range []struct {
		id        string
		delivered bool
	}{{"old-pending", false}, {"old-delivered", true}} {
		deliveredAt := "NULL"
		if m.delivered {
			deliveredAt = "UTC_TIMESTAMP(3)"
		}
		if _, e := s.DB.Exec(`INSERT INTO messages(id,conversation_id,client_msg_id,sender_device_id,receiver_device_id,msg_type,content,created_at,delivered_at) VALUES(?,'conv',?,?,?,'text','x',?,`+deliveredAt+`)`, m.id, m.id, from, to, old); e != nil {
			t.Fatal(e)
		}
	}
	// Nothing aged out under a policy that keeps everything for a year → no job.
	if code, _ := owner.request("PUT", "retention", map[string]any{"offline_days": 365, "delivered_days": 0, "transfer_days": 0, "reason": "放宽测试"}); code != 200 {
		t.Fatal(code)
	}
	s.QueueRetention(ctx)
	if code, out := owner.request("GET", "jobs", nil); code != 200 || out["total"].(float64) != 0 {
		t.Fatal("job queued with nothing to delete", out)
	}
	// 30 days: the undelivered 50-day-old message qualifies, the delivered one is kept (delivered_days=0).
	if code, _ := owner.request("PUT", "retention", map[string]any{"offline_days": 30, "delivered_days": 0, "transfer_days": 0, "reason": "恢复默认"}); code != 200 {
		t.Fatal(code)
	}
	s.QueueRetention(ctx)
	s.QueueRetention(ctx) // a second tick must not stack another job
	code, out := owner.request("GET", "jobs", nil)
	if code != 200 || out["total"].(float64) != 1 || out["items"].([]any)[0].(map[string]any)["actor"] != "system" {
		t.Fatal("scheduled job", out)
	}
	s.WorkOne(ctx)
	var left, status string
	if e := s.DB.QueryRow(`SELECT GROUP_CONCAT(id) FROM messages`).Scan(&left); e != nil || left != "old-delivered" {
		t.Fatal("retention deleted the wrong rows:", left, e)
	}
	if e := s.DB.QueryRow(`SELECT status FROM admin_jobs`).Scan(&status); e != nil || status != "COMPLETED" {
		t.Fatal("job status", status, e)
	}
	var n int
	if e := s.DB.QueryRow(`SELECT COUNT(*) FROM admin_audit WHERE actor='system'`).Scan(&n); e != nil || n != 2 {
		t.Fatal("system audit entries", n, e)
	}
}

func TestAdminConsoleStaticAndCSP(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "index.html"), []byte("<html>console</html>"), 0o644)
	h := NewRouter(nil, nil, nil, 0, 0, Options{AdminDir: dir})
	get := func(p string) *httptest.ResponseRecorder {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("GET", p, nil))
		return w
	}
	if w := get("/admin"); w.Code != http.StatusMovedPermanently || w.Header().Get("Location") != "/admin/" {
		t.Fatal("/admin redirect", w.Code)
	}
	w := get("/admin/")
	if w.Code != 200 || !strings.Contains(w.Body.String(), "console") {
		t.Fatal("console shell", w.Code)
	}
	csp := w.Header().Get("Content-Security-Policy")
	for _, bad := range []string{"wasm", "ws:", "wss:", "blob:", "https:"} {
		if strings.Contains(csp, bad) {
			t.Fatalf("admin CSP too loose (%s): %s", bad, csp)
		}
	}
	if !strings.Contains(csp, "frame-ancestors 'none'") || !strings.Contains(csp, "connect-src 'self'") {
		t.Fatal(csp)
	}
}

func TestAdminMonitor(t *testing.T) {
	_, h := setupAdmin(t)
	anon := &adminClient{h: h}
	if code, _ := anon.request("GET", "monitor", nil); code != 401 {
		t.Fatal("monitor reachable without a session", code)
	}
	viewer := managementLogin(t, h, "viewer")
	code, out := viewer.request("GET", "monitor", nil)
	if code != 200 {
		t.Fatal(code, out)
	}
	cur := out["current"].(map[string]any)
	if cur["goroutines"].(float64) < 1 || cur["rss_bytes"].(float64) <= 0 || cur["heap_bytes"].(float64) <= 0 || cur["cpus"].(float64) < 1 {
		t.Fatal("empty reading", cur)
	}
	if len(out["history"].([]any)) < 1 || out["interval_seconds"].(float64) != 5 {
		t.Fatal("history", out)
	}
	if _, ok := cur["db_max"]; !ok {
		t.Fatal("db pool missing", cur)
	}
}
