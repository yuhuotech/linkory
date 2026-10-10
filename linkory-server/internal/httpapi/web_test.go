package httpapi

import (
	"compress/gzip"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWebHandlerServesShellAndAssets(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "index.html"), []byte("<html>shell</html>"), 0o644)
	os.WriteFile(filepath.Join(dir, "main.dart.js"), []byte("js"), 0o644)
	h := NewRouter(nil, nil, nil, 0, 0, Options{WebDir: dir})

	get := func(p string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", p, nil))
		return rec
	}
	if r := get("/"); r.Code != 200 || !strings.Contains(r.Body.String(), "shell") {
		t.Fatalf("/: %d %q", r.Code, r.Body.String())
	}
	if r := get("/chat/42"); r.Code != 200 || !strings.Contains(r.Body.String(), "shell") {
		t.Fatalf("spa fallback: %d", r.Code)
	}
	if r := get("/main.dart.js"); r.Code != 200 || r.Body.String() != "js" {
		t.Fatalf("asset: %d %q", r.Code, r.Body.String())
	}
	if r := get("/missing.js"); r.Code != 404 {
		t.Fatalf("missing asset must 404, got %d", r.Code)
	}
	if r := get("/../etc/passwd"); r.Code == 200 && !strings.Contains(r.Body.String(), "shell") {
		t.Fatal("path traversal")
	}
	if csp := get("/").Header().Get("Content-Security-Policy"); !strings.Contains(csp, "frame-ancestors 'none'") {
		t.Fatalf("csp: %q", csp)
	}
	if r := get("/healthz"); r.Code != 200 || strings.Contains(r.Body.String(), "shell") {
		t.Fatal("API routes must win over the web shell")
	}
}

func TestWebDevicesAreCappedAndLeastRecentIsRetired(t *testing.T) {
	h := setup(t)
	call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": "carol", "password": "password123"})
	webLogin := func(i int) (int, map[string]any) {
		return call(h, "POST", "/api/v1/auth/login", "", map[string]any{"username": "carol", "password": "password123",
			"device": map[string]any{"name": fmt.Sprintf("Chrome %d", i), "type": "web", "public_key": fmt.Sprintf("pk%d", i)}})
	}
	var first map[string]any
	for i := 0; i < 12; i++ {
		code, out := webLogin(i)
		if code != 200 {
			t.Fatalf("web login %d: %d %v", i, code, out)
		}
		if i == 0 {
			first = out
		}
	}
	// A native device still registers normally and sees at most 10 browsers + itself.
	mac := login(t, h, "carol", "mac")
	_, list := call(h, "GET", "/api/v1/devices", mac["access_token"].(string), nil)
	devs := list["devices"].([]any)
	if len(devs) != 11 {
		t.Fatalf("want 10 web + 1 native, got %d", len(devs))
	}
	for _, d := range devs {
		if d.(map[string]any)["id"] == first["device_id"] {
			t.Fatal("oldest web device should have been retired")
		}
	}
	// The retired browser's token no longer works.
	if code, _ := call(h, "GET", "/api/v1/devices", first["access_token"].(string), nil); code != http.StatusUnauthorized {
		t.Fatalf("retired device token: %d", code)
	}
}

func TestWebHandlerGzipsLargeAssets(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "index.html"), []byte("<html>shell</html>"), 0o644)
	os.WriteFile(filepath.Join(dir, "main.dart.js"), []byte(strings.Repeat("var a=1;", 1000)), 0o644)
	os.WriteFile(filepath.Join(dir, "pic.png"), []byte("png"), 0o644)
	h := NewRouter(nil, nil, nil, 0, 0, Options{WebDir: dir})
	req := httptest.NewRequest("GET", "/main.dart.js", nil)
	req.Header.Set("Accept-Encoding", "gzip")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Header().Get("Content-Encoding") != "gzip" || rec.Body.Len() >= 8000 {
		t.Fatalf("not compressed: %q %d bytes", rec.Header().Get("Content-Encoding"), rec.Body.Len())
	}
	zr, err := gzip.NewReader(rec.Body)
	if err != nil {
		t.Fatal(err)
	}
	if b, _ := io.ReadAll(zr); len(b) != 8000 {
		t.Fatalf("decoded %d bytes", len(b))
	}
	req = httptest.NewRequest("GET", "/pic.png", nil)
	req.Header.Set("Accept-Encoding", "gzip")
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Header().Get("Content-Encoding") != "" || rec.Body.String() != "png" {
		t.Fatal("images must not be recompressed")
	}
}

func TestSameNamedDevicesGetADistinguishingSuffix(t *testing.T) {
	h := setup(t)
	call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": "erin", "password": "password123"})
	var ids []string
	for i := 0; i < 3; i++ {
		code, out := call(h, "POST", "/api/v1/auth/login", "", map[string]any{"username": "erin", "password": "password123",
			"device": map[string]any{"name": "Chrome · macOS", "type": "web", "public_key": fmt.Sprintf("pk%d", i)}})
		if code != 200 {
			t.Fatal(code, out)
		}
		ids = append(ids, out["access_token"].(string))
	}
	_, list := call(h, "GET", "/api/v1/devices", ids[0], nil)
	var names []string
	for _, d := range list["devices"].([]any) {
		names = append(names, d.(map[string]any)["name"].(string))
	}
	want := map[string]bool{"Chrome · macOS": true, "Chrome · macOS (2)": true, "Chrome · macOS (3)": true}
	if len(names) != 3 {
		t.Fatalf("names %v", names)
	}
	for _, n := range names {
		if !want[n] {
			t.Fatalf("unexpected name %q in %v", n, names)
		}
	}
}

func TestCORSOnlyForListedOrigins(t *testing.T) {
	h := NewRouter(nil, nil, nil, 0, 0, Options{CORSOrigins: []string{"https://my.example.com"}})
	do := func(method, origin, path string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, nil)
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}
	if r := do("GET", "https://my.example.com", "/healthz"); r.Header().Get("Access-Control-Allow-Origin") != "https://my.example.com" {
		t.Fatal("listed origin must be allowed")
	}
	if r := do("GET", "https://evil.example.org", "/healthz"); r.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatal("unlisted origin must not be allowed")
	}
	r := do("OPTIONS", "https://my.example.com", "/api/v1/transfers/x/data")
	if r.Code != 204 || !strings.Contains(r.Header().Get("Access-Control-Allow-Headers"), "Authorization") || !strings.Contains(r.Header().Get("Access-Control-Allow-Methods"), "PUT") {
		t.Fatalf("preflight: %d %v", r.Code, r.Header())
	}
	if r := do("GET", "", "/healthz"); r.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatal("no Origin, no CORS headers")
	}
	// Without configuration nothing changes.
	plain := NewRouter(nil, nil, nil, 0, 0, Options{})
	req := httptest.NewRequest("GET", "/healthz", nil)
	req.Header.Set("Origin", "https://my.example.com")
	rec := httptest.NewRecorder()
	plain.ServeHTTP(rec, req)
	if rec.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatal("CORS must be off by default")
	}
}

func TestWebConfigAndCSPFollowCustomServerSetting(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "index.html"), []byte("x"), 0o644)
	for _, custom := range []bool{false, true} {
		h := NewRouter(nil, nil, nil, 0, 0, Options{WebDir: dir, WebCustomServer: custom})
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", "/web-config.json", nil))
		want := fmt.Sprintf(`"custom_server":%v`, custom)
		if !strings.Contains(rec.Body.String(), want) {
			t.Fatalf("web-config: %s", rec.Body.String())
		}
		rec = httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", "/", nil))
		csp := rec.Header().Get("Content-Security-Policy")
		if strings.Contains(csp, "connect-src 'self' https: wss:") != custom {
			t.Fatalf("custom=%v but csp=%q", custom, csp)
		}
	}
}

func TestReloginRefreshesVersionButKeepsName(t *testing.T) {
	h := setup(t)
	call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": "gina", "password": "password123"})
	first := login(t, h, "gina", "laptop")
	id, tok := first["device_id"].(string), first["access_token"].(string)
	call(h, "PATCH", "/api/v1/devices/"+id, tok, map[string]any{"name": "My renamed laptop"})
	call(h, "POST", "/api/v1/auth/login", "", map[string]any{"username": "gina", "password": "password123",
		"device": map[string]any{"device_id": id, "name": "laptop", "app_version": "9.9.9", "os_version": "NewOS 2"}})
	_, list := call(h, "GET", "/api/v1/devices", tok, nil)
	d := list["devices"].([]any)[0].(map[string]any)
	if d["app_version"] != "9.9.9" || d["os_version"] != "NewOS 2" || d["name"] != "My renamed laptop" {
		t.Fatalf("device after re-login: %v", d)
	}
}

func TestDeviceReportsItsOwnVersion(t *testing.T) {
	h := setup(t)
	call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": "hank", "password": "password123"})
	a := login(t, h, "hank", "a")
	b := login(t, h, "hank", "b")
	at, aid, bid := a["access_token"].(string), a["device_id"].(string), b["device_id"].(string)
	if code, _ := call(h, "PATCH", "/api/v1/devices/"+aid, at, map[string]any{"app_version": "2.0.0"}); code != 204 {
		t.Fatalf("self version update: %d", code)
	}
	call(h, "PATCH", "/api/v1/devices/"+bid, at, map[string]any{"app_version": "6.6.6"}) // someone else's: ignored
	_, list := call(h, "GET", "/api/v1/devices", at, nil)
	got := map[string]string{}
	for _, d := range list["devices"].([]any) {
		m := d.(map[string]any)
		got[m["id"].(string)] = m["app_version"].(string)
	}
	if got[aid] != "2.0.0" || got[bid] == "6.6.6" {
		t.Fatalf("versions: %v", got)
	}
}
