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
	h := NewRouter(nil, nil, nil, 0, 0, dir)

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
	h := NewRouter(nil, nil, nil, 0, 0, dir)
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
