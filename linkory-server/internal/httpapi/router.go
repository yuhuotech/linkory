package httpapi

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"time"

	"github.com/linkory/linkory-server/internal/auth"
	"github.com/linkory/linkory-server/internal/devices"
	"github.com/linkory/linkory-server/internal/messaging"
	"github.com/linkory/linkory-server/internal/transfers"
)

const Version = "0.1.0"

func NewRouter(db *sql.DB, authSvc *auth.Service, hub *messaging.Hub, offlineTTL time.Duration, maxTransfer uint64) http.Handler {
	mux := http.NewServeMux()
	if authSvc != nil {
		authSvc.Routes(mux)
		(&devices.Handler{DB: db, Auth: authSvc, OnRemove: func(id string) { hub.Disconnect(id) }}).Routes(mux)
		tr := &transfers.Handler{Svc: &transfers.Service{DB: db, MaxBytes: maxTransfer}, Auth: authSvc, Hub: hub}
		tr.Routes(mux)
		go tr.RunSweeper(context.Background())
		(&messaging.Handler{Hub: hub, Auth: authSvc, OfflineTTL: offlineTTL}).Routes(mux)
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
