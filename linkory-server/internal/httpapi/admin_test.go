package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/linkory/linkory-server/internal/admin"
	"github.com/linkory/linkory-server/internal/auth"
	"github.com/linkory/linkory-server/internal/database"
	"github.com/linkory/linkory-server/internal/messaging"
)

type adminClient struct {
	h      http.Handler
	cookie *http.Cookie
	csrf   string
}

func (c *adminClient) request(method, path string, body any) (int, map[string]any) {
	var b bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&b).Encode(body)
	}
	r := httptest.NewRequest(method, "http://admin.test/api/admin/v1/"+path, &b)
	r.Header.Set("Origin", "http://admin.test")
	r.Header.Set("X-Linkory-Admin", "1")
	r.Header.Set("X-CSRF-Token", c.csrf)
	if c.cookie != nil {
		r.AddCookie(c.cookie)
	}
	w := httptest.NewRecorder()
	c.h.ServeHTTP(w, r)
	out := map[string]any{}
	if w.Body.Len() > 0 {
		_ = json.Unmarshal(w.Body.Bytes(), &out)
	}
	if path == "auth/login" && w.Code == 200 {
		c.cookie = w.Result().Cookies()[0]
		c.csrf = out["csrf_token"].(string)
	}
	return w.Code, out
}
func setupAdmin(t *testing.T) (*admin.Service, http.Handler) {
	t.Helper()
	_ = setup(t) // real MySQL fixture and migrations
	db, e := database.Open(os.Getenv("LINKORY_TEST_DSN"))
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { db.Close() })
	hub := messaging.NewHub(db, &messaging.Store{DB: db})
	s := admin.NewService(db, hub, 30)
	s.SecureCookie = false
	for _, v := range []struct{ name, role string }{{"owner", "admin"}, {"viewer", "readonly"}} {
		if e = s.CreateAccount(context.Background(), v.name, "admin-test-password-123", v.role); e != nil {
			t.Fatal(e)
		}
	}
	return s, NewRouter(db, auth.NewService(db, []byte("test-secret-test-secret-test-secret"), time.Minute, time.Hour), hub, 30*24*time.Hour, 10<<20, Options{Admin: s})
}
func managementLogin(t *testing.T, h http.Handler, name string) *adminClient {
	t.Helper()
	c := &adminClient{h: h}
	code, _ := c.request("POST", "auth/login", map[string]any{"username": name, "password": "admin-test-password-123"})
	if code != 200 {
		t.Fatalf("admin login: %d", code)
	}
	if !c.cookie.HttpOnly || c.cookie.SameSite != http.SameSiteStrictMode {
		t.Fatal("missing cookie protections")
	}
	return c
}
func TestAdminIsolationAndMutations(t *testing.T) {
	s, h := setupAdmin(t)
	owner := managementLogin(t, h, "owner")
	viewer := managementLogin(t, h, "viewer")
	call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": "alice", "password": "password123"})
	user := login(t, h, "alice", "Mac")
	uid := fmt.Sprint(user["user_id"])
	device := user["device_id"].(string)
	for _, path := range []string{"overview", "users", "users/" + uid, "devices", "devices/" + device, "transfers", "audit", "retention", "jobs"} {
		code, _ := viewer.request("GET", path, nil)
		if code != 200 {
			t.Fatalf("readonly GET %s: %d", path, code)
		}
	}
	r := httptest.NewRequest("GET", "http://admin.test/api/admin/v1/users", nil)
	r.Header.Set("Authorization", "Bearer "+user["access_token"].(string))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatal("user JWT reached management API", w.Code)
	}
	code, _ := viewer.request("POST", "users/"+uid+"/disable", map[string]any{"reason": "只读不允许"})
	if code != 403 {
		t.Fatal("readonly write", code)
	}
	oldCSRF := owner.csrf
	owner.csrf = "wrong"
	code, _ = owner.request("POST", "users/"+uid+"/disable", map[string]any{"reason": "防 CSRF 测试"})
	owner.csrf = oldCSRF
	if code != 403 {
		t.Fatal("CSRF", code)
	}
	wsServer := httptest.NewServer(h)
	defer wsServer.Close()
	ws := dial(t, wsServer, user["access_token"].(string))
	ws.expect("presence.snapshot")
	code, _ = owner.request("POST", "users/"+uid+"/disable", map[string]any{"reason": "用户违规测试"})
	if code != 204 {
		t.Fatal("disable", code)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, _, e := ws.c.Read(ctx); e == nil {
		t.Fatal("banned websocket stayed open")
	}
	if code, _ := call(h, "GET", "/api/v1/devices", user["access_token"].(string), nil); code != 401 {
		t.Fatal("old JWT survived", code)
	}
	if code, _ := call(h, "POST", "/api/v1/auth/refresh", "", map[string]any{"refresh_token": user["refresh_token"]}); code != 401 {
		t.Fatal("refresh survived", code)
	}
	if code, _ := call(h, "POST", "/api/v1/auth/login", "", map[string]any{"username": "alice", "password": "password123", "device": dev("Mac")}); code != 403 {
		t.Fatal("banned user logged in", code)
	}
	code, _ = owner.request("POST", "users/"+uid+"/enable", map[string]any{"reason": "恢复账号测试"})
	if code != 204 {
		t.Fatal(code)
	}
	newer := login(t, h, "alice", "new")
	if newer["access_token"] == nil {
		t.Fatal("unban login failed")
	}
	// Audit failure must not commit business state changes.
	if _, e := s.DB.Exec(`RENAME TABLE admin_audit TO admin_audit_unavailable`); e != nil {
		t.Fatal(e)
	}
	code, _ = owner.request("POST", "users/"+uid+"/disable", map[string]any{"reason": "审计失败回滚"})
	if _, e := s.DB.Exec(`RENAME TABLE admin_audit_unavailable TO admin_audit`); e != nil {
		t.Fatal(e)
	}
	if code != 500 {
		t.Fatal("audit failure", code)
	}
	var disabled any
	if e := s.DB.QueryRow(`SELECT disabled_at FROM users WHERE id=?`, uid).Scan(&disabled); e != nil || disabled != nil {
		t.Fatal("mutation escaped audit failure", e, disabled)
	}
	code, out := owner.request("GET", "users", nil)
	raw, _ := json.Marshal(out)
	if code != 200 || bytes.Contains(raw, []byte("password_hash")) {
		t.Fatal("sensitive user data exposed")
	}
}
func TestAdminJobsAndPolicy(t *testing.T) {
	s, h := setupAdmin(t)
	c := managementLogin(t, h, "owner")
	call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": "alice", "password": "password123"})
	a := login(t, h, "alice", "one")
	b := login(t, h, "alice", "two")
	uid := fmt.Sprint(a["user_id"])
	sender := a["device_id"].(string)
	receiver := b["device_id"].(string)
	old := time.Now().UTC().AddDate(0, 0, -50)
	_, e := s.DB.Exec(`INSERT INTO conversations(id,user_id,device_lo,device_hi) VALUES('conv',?,?,?)`, uid, sender, receiver)
	if e != nil {
		t.Fatal(e)
	}
	_, e = s.DB.Exec(`INSERT INTO messages(id,conversation_id,client_msg_id,sender_device_id,receiver_device_id,msg_type,content,created_at) VALUES('old','conv','old',?,?,'text','private-message-must-not-be-exposed',?)`, sender, receiver, old)
	if e != nil {
		t.Fatal(e)
	}
	code, p := c.request("POST", "retention/preview", map[string]any{"kind": "retention"})
	if code != 200 {
		t.Fatal(code, p)
	}
	if p["counts"].(map[string]any)["messages"].(float64) != 1 {
		t.Fatal(p)
	}
	// A new message after the preview must survive the fixed scope.
	_, e = s.DB.Exec(`INSERT INTO messages(id,conversation_id,client_msg_id,sender_device_id,receiver_device_id,msg_type,content) VALUES('new','conv','new',?,?,'text','new content')`, sender, receiver)
	if e != nil {
		t.Fatal(e)
	}
	code, j := c.request("POST", "jobs", map[string]any{"preview_id": p["preview_id"], "confirm": "删除", "reason": "保留策略测试"})
	if code != 202 {
		t.Fatal(code, j)
	}
	if code, _ := c.request("POST", "jobs", map[string]any{"preview_id": p["preview_id"], "confirm": "删除", "reason": "重复预览测试"}); code != 409 {
		t.Fatal("preview replay", code)
	}
	s.WorkOne(context.Background())
	code, result := c.request("GET", "jobs/"+j["id"].(string), nil)
	if code != 200 || result["status"] != "COMPLETED" {
		t.Fatal(code, result)
	}
	var n int
	s.DB.QueryRow(`SELECT COUNT(*) FROM messages WHERE id='new'`).Scan(&n)
	if n != 1 {
		t.Fatal("new message deleted")
	}
	code, _ = c.request("PUT", "retention", map[string]any{"offline_days": 10, "delivered_days": 0, "transfer_days": 20, "reason": "更新策略测试"})
	if code != 200 {
		t.Fatal(code)
	}
	code, p = c.request("POST", "retention/preview", map[string]any{"kind": "user_delete", "user_id": a["user_id"]})
	if code != 200 {
		t.Fatal(code, p)
	}
	code, j = c.request("POST", "jobs", map[string]any{"preview_id": p["preview_id"], "confirm": "删除", "reason": "用户申请注销"})
	if code != 202 {
		t.Fatal(code, j)
	}
	s.WorkOne(context.Background())
	for _, table := range []string{"users", "devices", "transfer_tasks", "conversations"} {
		col := "user_id"
		if table == "users" {
			col = "id"
		}
		s.DB.QueryRow("SELECT COUNT(*) FROM "+table+" WHERE "+col+"=?", uid).Scan(&n)
		if n != 0 {
			t.Fatal("residual user data", table, n)
		}
	}
	code, out := c.request("GET", "audit", nil)
	raw, _ := json.Marshal(out)
	if code != 200 || strings.Contains(string(raw), "private-message") {
		t.Fatal("audit leaked content")
	}
}

func TestAdminDeviceTransferAndSessionLifecycle(t *testing.T) {
	s, h := setupAdmin(t)
	c := managementLogin(t, h, "owner")
	second := managementLogin(t, h, "owner")
	call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": "alice", "password": "password123"})
	a := login(t, h, "alice", "one")
	b := login(t, h, "alice", "two")
	uid := a["user_id"]
	sender := a["device_id"].(string)
	receiver := b["device_id"].(string)
	_, e := s.DB.Exec(`INSERT INTO transfer_tasks(id,user_id,sender_device_id,receiver_device_id,file_name,size,sha256,status) VALUES('test-task',?,?,?,'private-file.txt',1024,REPEAT('a',64),'WAITING_ACCEPT')`, uid, sender, receiver)
	if e != nil {
		t.Fatal(e)
	}
	code, _ := c.request("POST", "retention/preview", map[string]any{"kind": "user_delete", "user_id": uid})
	if code != 409 {
		t.Fatal("active transfers allowed account deletion", code)
	}
	code, out := c.request("GET", "transfers/test-task", nil)
	raw, _ := json.Marshal(out)
	if code != 200 || bytes.Contains(raw, []byte("lan_secret")) || bytes.Contains(raw, []byte("sha256")) {
		t.Fatal("transfer metadata leaked secret", code, string(raw))
	}
	code, _ = c.request("POST", "transfers/test-task/cancel", map[string]any{"reason": "取消测试任务"})
	if code != 204 {
		t.Fatal("cancel", code)
	}
	code, _ = c.request("POST", "transfers/test-task/cancel", map[string]any{"reason": "重复取消测试"})
	if code != 409 {
		t.Fatal("terminal state guard", code)
	}
	code, _ = c.request("POST", "devices/"+sender+"/disconnect", map[string]any{"reason": "强制下线测试"})
	if code != 204 {
		t.Fatal(code)
	}
	if code, _ := call(h, "GET", "/api/v1/devices", a["access_token"].(string), nil); code != 401 {
		t.Fatal("disconnect token remains", code)
	}
	code, _ = c.request("POST", "devices/"+receiver+"/remove", map[string]any{"reason": "移除设备测试"})
	if code != 204 {
		t.Fatal(code)
	}
	code, _ = c.request("POST", "auth/password", map[string]any{"old_password": "admin-test-password-123", "new_password": "new-admin-password-456"})
	if code != 204 {
		t.Fatal("change admin password", code)
	}
	if code, _ := second.request("GET", "auth/me", nil); code != 401 {
		t.Fatal("other admin session survived", code)
	}
	if code, _ := c.request("GET", "auth/me", nil); code != 200 {
		t.Fatal("current session lost", code)
	}
	if code, _ := c.request("GET", "users?page_size=99999", nil); code != 200 {
		t.Fatal(code)
	}
	if code, _ := c.request("GET", "transfers?from=wrong", nil); code != 400 {
		t.Fatal("bad date", code)
	}
	if code, _ := c.request("POST", "auth/logout", nil); code != 204 {
		t.Fatal(code)
	}
	if code, _ := c.request("GET", "auth/me", nil); code != 401 {
		t.Fatal("logout did not revoke", code)
	}
	anon := &adminClient{h: h}
	for i := 0; i < 5; i++ {
		code, _ = anon.request("POST", "auth/login", map[string]any{"username": "owner", "password": "wrong-password"})
		if code != 401 {
			t.Fatal("failed login", i, code)
		}
	}
	code, _ = anon.request("POST", "auth/login", map[string]any{"username": "owner", "password": "new-admin-password-456"})
	if code != 429 {
		t.Fatal("login limit", code)
	}
}

func TestAdminFailedJobRetryAndPreviewExpiry(t *testing.T) {
	s, h := setupAdmin(t)
	c := managementLogin(t, h, "owner")
	call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": "alice", "password": "password123"})
	a := login(t, h, "alice", "one")
	b := login(t, h, "alice", "two")
	uid := a["user_id"]
	code, p := c.request("POST", "retention/preview", map[string]any{"kind": "user_messages", "user_id": uid})
	if code != 200 {
		t.Fatal(code)
	}
	s.DB.Exec(`UPDATE admin_previews SET expires_at=UTC_TIMESTAMP(3)-INTERVAL 1 MINUTE WHERE id=?`, p["preview_id"])
	code, _ = c.request("POST", "jobs", map[string]any{"preview_id": p["preview_id"], "confirm": "删除", "reason": "过期预览测试"})
	if code != 409 {
		t.Fatal("expired preview", code)
	}
	code, p = c.request("POST", "retention/preview", map[string]any{"kind": "user_delete", "user_id": uid})
	if code != 200 {
		t.Fatal(code)
	}
	code, j := c.request("POST", "jobs", map[string]any{"preview_id": p["preview_id"], "confirm": "删除", "reason": "注销重试测试"})
	if code != 202 {
		t.Fatal(code)
	}
	if code, _ := c.request("POST", fmt.Sprintf("users/%v/enable", uid), map[string]any{"reason": "不允许恢复待注销账号"}); code != 409 {
		t.Fatal("enabled pending deletion", code)
	}
	// Simulate an already-authorized transfer racing the deletion request.
	_, e := s.DB.Exec(`INSERT INTO transfer_tasks(id,user_id,sender_device_id,receiver_device_id,file_name,size,sha256,status) VALUES('racing-task',?,?,?,'racing.txt',1,REPEAT('a',64),'WAITING_ACCEPT')`, uid, a["device_id"], b["device_id"])
	if e != nil {
		t.Fatal(e)
	}
	s.WorkOne(context.Background())
	code, out := c.request("GET", "jobs/"+j["id"].(string), nil)
	if code != 200 || out["status"] != "FAILED" {
		t.Fatal(code, out)
	}
	c.request("POST", "transfers/racing-task/cancel", map[string]any{"reason": "结束活动任务"})
	code, _ = c.request("POST", "jobs/"+j["id"].(string)+"/retry", map[string]any{"reason": "活动任务已停止，继续注销"})
	if code != 204 {
		t.Fatal("retry", code)
	}
	s.WorkOne(context.Background())
	_, out = c.request("GET", "jobs/"+j["id"].(string), nil)
	if out["status"] != "COMPLETED" {
		t.Fatal(out)
	}
}
