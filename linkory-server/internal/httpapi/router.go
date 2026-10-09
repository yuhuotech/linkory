package httpapi

import (
	"context"
	"crypto/subtle"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
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

func NewRouter(db *sql.DB, authSvc *auth.Service, hub *messaging.Hub, offlineTTL time.Duration, maxTransfer uint64) http.Handler {
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
		(&messaging.Handler{Hub: hub, Auth: authSvc, OfflineTTL: offlineTTL}).Routes(mux)
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
	return mux
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
