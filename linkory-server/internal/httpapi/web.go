package httpapi

import (
	"compress/gzip"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// webHandler serves a Flutter web build (the browser edition of the app) from dir. It sits on "/" so every
// path the API registers keeps priority; the page and the API share one origin, which means no CORS and the
// WebSocket origin check passes by itself.
func webHandler(opt Options) http.Handler {
	dir := opt.WebDir
	connect := "'self' ws: wss: blob:"
	if opt.WebCustomServer {
		// The page may talk to a server of the user's choice: HTTPS only (browsers block mixed content), plus this
		// machine for people running a server locally.
		connect = "'self' https: wss: http://localhost:* http://127.0.0.1:* ws://localhost:* ws://127.0.0.1:* blob:"
	}
	files := http.FileServer(http.Dir(dir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		// The page holds the account's tokens and device key: no third-party scripts, no framing.
		h.Set("Content-Security-Policy", "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; "+
			"img-src 'self' data: blob:; font-src 'self' data:; connect-src "+connect+"; worker-src 'self' blob:; "+
			"object-src 'none'; base-uri 'self'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-cache") // revalidate (ETag) so a new release is picked up immediately

		if strings.Contains(r.Header.Get("Accept-Encoding"), "gzip") && compressible(r.URL.Path) {
			// Flutter's script, wasm and fonts are large and compress well; many users are far from the server.
			h.Set("Content-Encoding", "gzip")
			h.Add("Vary", "Accept-Encoding")
			h.Del("Content-Length")
			gz := gzip.NewWriter(w)
			defer gz.Close()
			w = &gzipResponse{ResponseWriter: w, Writer: gz}
		}

		p := path.Clean("/" + r.URL.Path)
		if p != "/" && !strings.HasPrefix(p, "/.") {
			if st, err := os.Stat(filepath.Join(dir, filepath.FromSlash(p))); err == nil && !st.IsDir() {
				files.ServeHTTP(w, r)
				return
			}
			if path.Ext(p) != "" { // a missing asset is a 404, not the app shell
				http.NotFound(w, r)
				return
			}
		}
		http.ServeFile(w, r, filepath.Join(dir, "index.html"))
	})
}

func compressible(p string) bool {
	switch strings.ToLower(path.Ext(p)) {
	case "", ".html", ".js", ".mjs", ".json", ".wasm", ".ttf", ".otf", ".css", ".svg", ".map":
		return true
	}
	return false
}

type gzipResponse struct {
	http.ResponseWriter
	io.Writer
}

func (g *gzipResponse) Write(b []byte) (int, error) { return g.Writer.Write(b) }

// cors lets the API be called from the listed page origins (browsers only: native clients ignore it). Credentials
// are never used (the token goes in the Authorization header), so no Allow-Credentials.
func cors(origins []string, next http.Handler) http.Handler {
	if len(origins) == 0 {
		return next
	}
	allowed := func(o string) bool {
		for _, a := range origins {
			if a == "*" || a == o {
				return true
			}
		}
		return false
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		o := r.Header.Get("Origin")
		if o != "" && (strings.HasPrefix(r.URL.Path, "/api/") || r.URL.Path == "/healthz") && allowed(o) {
			h := w.Header()
			h.Add("Vary", "Origin")
			h.Set("Access-Control-Allow-Origin", o)
			h.Set("Access-Control-Expose-Headers", "Content-Length")
			if r.Method == http.MethodOptions {
				h.Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
				h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
				h.Set("Access-Control-Max-Age", "600")
				w.WriteHeader(http.StatusNoContent)
				return
			}
		}
		next.ServeHTTP(w, r)
	})
}
