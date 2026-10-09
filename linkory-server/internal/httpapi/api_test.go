package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/linkory/linkory-server/internal/auth"
	"github.com/linkory/linkory-server/internal/database"
	"github.com/linkory/linkory-server/internal/messaging"
	"github.com/linkory/linkory-server/migrations"
)

// Integration tests need a MySQL database: LINKORY_TEST_DSN (its tables are dropped first).
func setup(t *testing.T) http.Handler {
	dsn := os.Getenv("LINKORY_TEST_DSN")
	if dsn == "" {
		t.Skip("LINKORY_TEST_DSN not set")
	}
	db, err := database.Open(dsn)
	if err != nil {
		t.Fatal(err)
	}
	for _, tb := range []string{"transfer_tasks", "messages", "conversations", "device_sessions", "devices", "users", "schema_migrations"} {
		db.Exec("DROP TABLE IF EXISTS " + tb)
	}
	if err := database.Migrate(db, migrations.FS); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	hub := messaging.NewHub(db, &messaging.Store{DB: db})
	return NewRouter(db, auth.NewService(db, []byte("test-secret-test-secret-test-secret"), time.Minute, time.Hour), hub, 30*24*time.Hour, 10<<20)
}

func call(h http.Handler, method, path, token string, body any) (int, map[string]any) {
	var buf bytes.Buffer
	if body != nil {
		json.NewEncoder(&buf).Encode(body)
	}
	req := httptest.NewRequest(method, path, &buf)
	req.RemoteAddr = "1.2.3.4:5"
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	var out map[string]any
	json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func dev(name string) map[string]any {
	return map[string]any{"name": name, "type": "macos", "public_key": "pk-" + name}
}

func login(t *testing.T, h http.Handler, user, name string) map[string]any {
	code, out := call(h, "POST", "/api/v1/auth/login", "", map[string]any{"username": user, "password": "password123", "device": dev(name)})
	if code != 200 {
		t.Fatalf("login %s: %d %v", user, code, out)
	}
	return out
}

func TestAccountsAndDevices(t *testing.T) {
	h := setup(t)
	for _, u := range []string{"alice", "bob"} {
		if code, out := call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": u, "password": "password123"}); code != 201 {
			t.Fatal(code, out)
		}
	}
	if code, _ := call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": "alice", "password": "password123"}); code != 409 {
		t.Fatalf("duplicate username: %d", code)
	}
	if code, _ := call(h, "POST", "/api/v1/auth/login", "", map[string]any{"username": "alice", "password": "wrong-pass", "device": dev("x")}); code != 401 {
		t.Fatalf("bad password: %d", code)
	}

	// AT-01/02: two devices under one account see each other.
	a1 := login(t, h, "alice", "mac")
	a2 := login(t, h, "alice", "win")
	tok1 := a1["access_token"].(string)
	code, list := call(h, "GET", "/api/v1/devices", tok1, nil)
	if code != 200 || len(list["devices"].([]any)) != 2 {
		t.Fatalf("list: %d %v", code, list)
	}

	// Re-login with a known device_id does not create a duplicate.
	again, _ := call(h, "POST", "/api/v1/auth/login", "", map[string]any{"username": "alice", "password": "password123",
		"device": map[string]any{"device_id": a1["device_id"]}})
	if again != 200 {
		t.Fatal("relogin", again)
	}
	_, list = call(h, "GET", "/api/v1/devices", tok1, nil)
	if len(list["devices"].([]any)) != 2 {
		t.Fatal("duplicate device created")
	}

	// AT-10: another account cannot see, rename or remove alice's devices.
	b := login(t, h, "bob", "bobmac")
	btok := b["access_token"].(string)
	_, bl := call(h, "GET", "/api/v1/devices", btok, nil)
	if len(bl["devices"].([]any)) != 1 {
		t.Fatalf("bob sees %v", bl)
	}
	path := "/api/v1/devices/" + a2["device_id"].(string)
	if code, _ := call(h, "PATCH", path, btok, map[string]any{"name": "pwned"}); code != 404 {
		t.Fatalf("cross-account rename: %d", code)
	}
	if code, _ := call(h, "DELETE", path, btok, nil); code != 404 {
		t.Fatalf("cross-account delete: %d", code)
	}
	if code, _ := call(h, "GET", "/api/v1/devices", "", nil); code != 401 {
		t.Fatal("unauthenticated list", code)
	}

	// Rename.
	if code, _ := call(h, "PATCH", path, tok1, map[string]any{"name": "办公室电脑"}); code != 204 {
		t.Fatal("rename", code)
	}

	// Refresh rotation + reuse detection.
	r1 := a1["refresh_token"].(string)
	code, rot := call(h, "POST", "/api/v1/auth/refresh", "", map[string]any{"refresh_token": r1})
	if code != 200 || rot["refresh_token"] == r1 {
		t.Fatalf("refresh: %d %v", code, rot)
	}
	if code, _ := call(h, "POST", "/api/v1/auth/refresh", "", map[string]any{"refresh_token": r1}); code != 401 {
		t.Fatal("reused refresh token accepted")
	}
	if code, _ := call(h, "GET", "/api/v1/devices", rot["access_token"].(string), nil); code != 401 {
		t.Fatal("session should be revoked after refresh-token reuse")
	}

	// Fresh login for the first device (its old sessions were revoked above).
	_, relog := call(h, "POST", "/api/v1/auth/login", "", map[string]any{"username": "alice", "password": "password123",
		"device": map[string]any{"device_id": a1["device_id"]}})
	tok1 = relog["access_token"].(string)

	// AT-11: removed device's credentials stop working immediately.
	if code, _ := call(h, "DELETE", path, tok1, nil); code != 204 {
		t.Fatal("remove", code)
	}
	if code, _ := call(h, "GET", "/api/v1/devices", a2["access_token"].(string), nil); code != 401 {
		t.Fatal("removed device token still valid")
	}
	if code, _ := call(h, "POST", "/api/v1/auth/refresh", "", map[string]any{"refresh_token": a2["refresh_token"]}); code != 401 {
		t.Fatal("removed device refresh still valid")
	}

	// Logout revokes the session.
	b2 := login(t, h, "bob", "bobwin")
	if code, _ := call(h, "POST", "/api/v1/auth/logout", b2["access_token"].(string), nil); code != 204 {
		t.Fatal("logout", code)
	}
	if code, _ := call(h, "GET", "/api/v1/devices", b2["access_token"].(string), nil); code != 401 {
		t.Fatal("token valid after logout")
	}

	// Login throttling.
	for i := 0; i < 6; i++ {
		call(h, "POST", "/api/v1/auth/login", "", map[string]any{"username": "carol", "password": fmt.Sprint("bad-pass-", i), "device": dev("c")})
	}
	if code, _ := call(h, "POST", "/api/v1/auth/login", "", map[string]any{"username": "carol", "password": "x", "device": dev("c")}); code != 429 {
		t.Fatalf("throttle: %d", code)
	}
}

// AUTH-008: changing the password verifies the old one and signs out the account's other devices.
func TestChangePassword(t *testing.T) {
	h := setup(t)
	call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": "pwuser", "password": "password123"})
	a, b := login(t, h, "pwuser", "mac"), login(t, h, "pwuser", "win")
	aTok, bTok := a["access_token"].(string), b["access_token"].(string)
	body := func(o, n string) map[string]any { return map[string]any{"old_password": o, "new_password": n} }

	if code, _ := call(h, "POST", "/api/v1/auth/password", aTok, body("wrong-password", "brand-new-pass-2")); code != 401 {
		t.Fatalf("wrong old password: %d", code)
	}
	if code, _ := call(h, "POST", "/api/v1/auth/password", aTok, body("password123", "short")); code != 400 {
		t.Fatalf("weak new password: %d", code)
	}
	if code, _ := call(h, "POST", "/api/v1/auth/password", aTok, body("password123", "brand-new-pass-2")); code != 204 && code != 200 {
		t.Fatalf("change: %d", code)
	}
	// The calling device keeps working; the other device is signed out.
	if code, _ := call(h, "GET", "/api/v1/devices", aTok, nil); code != 200 {
		t.Fatalf("caller after change: %d", code)
	}
	if code, _ := call(h, "GET", "/api/v1/devices", bTok, nil); code != 401 {
		t.Fatalf("other device after change: %d", code)
	}
	// Old password no longer logs in; the new one does.
	if code, _ := call(h, "POST", "/api/v1/auth/login", "", map[string]any{"username": "pwuser", "password": "password123", "device": dev("x")}); code != 401 {
		t.Fatalf("old password login: %d", code)
	}
	if code, _ := call(h, "POST", "/api/v1/auth/login", "", map[string]any{"username": "pwuser", "password": "brand-new-pass-2", "device": dev("y")}); code != 200 {
		t.Fatalf("new password login: %d", code)
	}
}
