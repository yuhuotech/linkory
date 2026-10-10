package httpapi

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"

	"github.com/linkory/linkory-server/internal/auth"
	"github.com/linkory/linkory-server/internal/devices"
	"github.com/linkory/linkory-server/internal/messaging"
	"github.com/linkory/linkory-server/internal/transfers"
)

// Version is overridden at release build time: -ldflags "-X .../httpapi.Version=1.2.3".
var Version = "0.1.0"

// MetricsToken enables GET /metrics (Prometheus text format) for callers presenting it as a bearer
// token. Empty = endpoint disabled.
var MetricsToken string

// Options are the deployment choices of a server that are not about the database.
type Options struct {
	// WebDir: a Flutter web build served on every path the API does not use ("" = none).
	WebDir string
	// CORSOrigins: page origins allowed to call the API from a browser (empty = same origin only; "*" = any).
	CORSOrigins []string
	// WebCustomServer: the served web page may also sign in to other servers (widens its Content-Security-Policy).
	WebCustomServer bool
}

// originHosts is the host part of CORSOrigins, for the WebSocket origin check.
func (o Options) originHosts() []string {
	var hosts []string
	for _, v := range o.CORSOrigins {
		if v == "*" {
			return []string{"*"}
		}
		if u, err := url.Parse(v); err == nil && u.Host != "" {
			hosts = append(hosts, u.Host)
		}
	}
	return hosts
}

func NewRouter(db *sql.DB, authSvc *auth.Service, hub *messaging.Hub, offlineTTL time.Duration, maxTransfer uint64, opt Options) http.Handler {
	mux := http.NewServeMux()
	if authSvc != nil {
		authSvc.OnRevoke = func(ids []string) {
			for _, id := range ids {
				hub.Disconnect(id)
			}
		}
		authSvc.Routes(mux)
		(&devices.Handler{DB: db, Auth: authSvc, OnRemove: func(id string) { hub.Disconnect(id) }}).Routes(mux)
		tr := &transfers.Handler{Svc: &transfers.Service{DB: db, MaxBytes: maxTransfer}, Auth: authSvc, Hub: hub}
		tr.Routes(mux)
		go tr.RunSweeper(context.Background())
		(&messaging.Handler{Hub: hub, Auth: authSvc, OfflineTTL: offlineTTL, OriginHosts: opt.originHosts()}).Routes(mux)
	}
	if opt.WebDir != "" {
		mux.Handle("GET /", webHandler(opt))
		mux.HandleFunc("GET /web-config.json", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Cache-Control", "no-cache")
			writeJSON(w, http.StatusOK, map[string]any{"custom_server": opt.WebCustomServer})
		})
	}
	if MetricsToken != "" && db != nil {
		mux.HandleFunc("GET /metrics", func(w http.ResponseWriter, r *http.Request) {
			if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+MetricsToken)) != 1 {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			var users, devs, msgs int64
			_ = db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&users)
			_ = db.QueryRow(`SELECT COUNT(*) FROM devices WHERE revoked_at IS NULL`).Scan(&devs)
			_ = db.QueryRow(`SELECT COUNT(*) FROM messages`).Scan(&msgs)
			w.Header().Set("Content-Type", "text/plain; version=0.0.4")
			fmt.Fprintf(w, "linkory_users %d\nlinkory_devices %d\nlinkory_messages %d\nlinkory_online_devices %d\nlinkory_relayed_bytes_total %d\n",
				users, devs, msgs, hub.OnlineCount(), transfers.RelayedBytes.Load())
			rows, err := db.Query(`SELECT status, mode, COUNT(*) FROM transfer_tasks GROUP BY status, mode`)
			if err == nil {
				defer rows.Close()
				for rows.Next() {
					var st, mode string
					var n int64
					if rows.Scan(&st, &mode, &n) == nil {
						fmt.Fprintf(w, "linkory_transfers{status=%q,mode=%q} %d\n", st, mode, n)
					}
				}
			}
		})
	}
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "version": Version})
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if db == nil || db.PingContext(ctx) != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "db_unavailable"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
	})
	return cors(opt.CORSOrigins, mux)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
