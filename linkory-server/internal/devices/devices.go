package devices

import (
	"database/sql"
	"net/http"
	"strings"
	"time"

	"github.com/linkory/linkory-server/internal/apiutil"
	"github.com/linkory/linkory-server/internal/auth"
)

type Device struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	Type       string     `json:"device_type"`
	OSVersion  string     `json:"os_version"`
	AppVersion string     `json:"app_version"`
	Status     string     `json:"status"`
	CreatedAt  time.Time  `json:"created_at"`
	LastSeenAt *time.Time `json:"last_seen_at"`
	Current    bool       `json:"current"`
}

type Handler struct {
	DB   *sql.DB
	Auth *auth.Service
	// OnRemove runs after a device is revoked (e.g. to drop its live connection).
	OnRemove func(deviceID string)
}

func (h *Handler) Routes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/devices", h.Auth.Middleware(h.list))
	mux.HandleFunc("PATCH /api/v1/devices/{id}", h.Auth.Middleware(h.rename))
	mux.HandleFunc("DELETE /api/v1/devices/{id}", h.Auth.Middleware(h.remove))
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) {
	p := auth.PrincipalFrom(r.Context())
	rows, err := h.DB.QueryContext(r.Context(), `SELECT id,name,device_type,os_version,app_version,status,created_at,last_seen_at
		FROM devices WHERE user_id=? AND revoked_at IS NULL ORDER BY created_at`, p.UserID)
	if err != nil {
		apiutil.Fail(w, err)
		return
	}
	defer rows.Close()
	out := []Device{}
	for rows.Next() {
		var d Device
		var seen sql.NullTime
		if err := rows.Scan(&d.ID, &d.Name, &d.Type, &d.OSVersion, &d.AppVersion, &d.Status, &d.CreatedAt, &seen); err != nil {
			apiutil.Fail(w, err)
			return
		}
		if seen.Valid {
			d.LastSeenAt = &seen.Time
		}
		d.Current = d.ID == p.DeviceID
		out = append(out, d)
	}
	apiutil.JSON(w, 200, map[string]any{"devices": out})
}

func (h *Handler) rename(w http.ResponseWriter, r *http.Request) {
	p := auth.PrincipalFrom(r.Context())
	var req struct {
		Name       *string `json:"name"`
		AppVersion string  `json:"app_version"`
		OSVersion  string  `json:"os_version"`
	}
	if err := apiutil.Decode(r, &req); err != nil {
		apiutil.Fail(w, err)
		return
	}
	id := r.PathValue("id")
	// A device reports its own version after an update (the list would otherwise keep showing the one it signed up with).
	if (req.AppVersion != "" || req.OSVersion != "") && id == p.DeviceID {
		_, _ = h.DB.ExecContext(r.Context(), `UPDATE devices SET app_version=IF(?='',app_version,?), os_version=IF(?='',os_version,?) WHERE id=? AND user_id=?`,
			clip(req.AppVersion, 32), clip(req.AppVersion, 32), clip(req.OSVersion, 64), clip(req.OSVersion, 64), id, p.UserID)
		if req.Name == nil {
			w.WriteHeader(204)
			return
		}
	}
	name := ""
	if req.Name != nil {
		name = strings.TrimSpace(*req.Name)
	}
	if name == "" || len([]rune(name)) > 64 {
		apiutil.Fail(w, apiutil.Err(400, "invalid_device_name", "device name must be 1-64 characters"))
		return
	}
	// Ownership is part of the WHERE clause: other accounts' devices look like 404.
	var exists int
	if err := h.DB.QueryRowContext(r.Context(), `SELECT 1 FROM devices WHERE id=? AND user_id=? AND revoked_at IS NULL`, id, p.UserID).Scan(&exists); err != nil {
		apiutil.Fail(w, apiutil.ErrNotFound)
		return
	}
	if _, err := h.DB.ExecContext(r.Context(), `UPDATE devices SET name=? WHERE id=? AND user_id=?`, name, id, p.UserID); err != nil {
		apiutil.Fail(w, err)
		return
	}
	w.WriteHeader(204)
}

func (h *Handler) remove(w http.ResponseWriter, r *http.Request) {
	p := auth.PrincipalFrom(r.Context())
	id := r.PathValue("id")
	res, err := h.DB.ExecContext(r.Context(), `UPDATE devices SET revoked_at=UTC_TIMESTAMP(3), status='revoked' WHERE id=? AND user_id=? AND revoked_at IS NULL`, id, p.UserID)
	if err != nil {
		apiutil.Fail(w, err)
		return
	}
	if n, _ := res.RowsAffected(); n == 0 {
		apiutil.Fail(w, apiutil.ErrNotFound)
		return
	}
	_, _ = h.DB.ExecContext(r.Context(), `UPDATE device_sessions SET revoked_at=UTC_TIMESTAMP(3) WHERE device_id=? AND revoked_at IS NULL`, id)
	if h.OnRemove != nil {
		h.OnRemove(id)
	}
	w.WriteHeader(204)
}

func clip(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}
