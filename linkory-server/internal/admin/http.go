package admin

import (
	"context"
	"database/sql"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/linkory/linkory-server/internal/apiutil"
	"github.com/linkory/linkory-server/internal/audit"
	"github.com/linkory/linkory-server/internal/transfers"
)

func (s *Service) Routes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/admin/v1/auth/login", s.login)
	read := func(path string, h http.HandlerFunc) { mux.HandleFunc("GET /api/admin/v1/"+path, s.protect(false, h)) }
	write := func(method, path string, h http.HandlerFunc) {
		mux.HandleFunc(method+" /api/admin/v1/"+path, s.protect(true, h))
	}
	read("auth/me", func(w http.ResponseWriter, r *http.Request) { apiutil.JSON(w, 200, actor(r)) })
	mux.HandleFunc("POST /api/admin/v1/auth/logout", s.protect(false, s.logout))
	mux.HandleFunc("POST /api/admin/v1/auth/password", s.protect(false, s.changePassword))
	read("overview", s.overview)
	read("users", s.users)
	read("users/{id}", s.userDetail)
	read("devices", s.devices)
	read("devices/{id}", s.deviceDetail)
	read("transfers", s.transferList)
	read("transfers/{id}", s.transferDetail)
	read("audit", s.auditList)
	read("retention", s.getPolicy)
	read("jobs", s.jobs)
	read("jobs/{id}", s.jobDetail)
	write("POST", "users/{id}/{action}", s.userAction)
	write("POST", "devices/{id}/{action}", s.deviceAction)
	write("POST", "transfers/{id}/cancel", s.cancelTransfer)
	write("PUT", "retention", s.setPolicy)
	write("POST", "retention/preview", s.preview)
	write("POST", "jobs", s.createJob)
	write("POST", "jobs/{id}/retry", s.retryJob)
}
func query(ctx context.Context, db interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
}, q string, args ...any) ([]map[string]any, error) {
	rows, e := db.QueryContext(ctx, q, args...)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	cols, e := rows.Columns()
	if e != nil {
		return nil, e
	}
	items := []map[string]any{}
	for rows.Next() {
		v := make([]any, len(cols))
		ptr := make([]any, len(cols))
		for i := range v {
			ptr[i] = &v[i]
		}
		if e = rows.Scan(ptr...); e != nil {
			return nil, e
		}
		row := map[string]any{}
		for i, name := range cols {
			switch val := v[i].(type) {
			case []byte:
				row[name] = string(val)
			default:
				row[name] = val
			}
		}
		items = append(items, row)
	}
	return items, rows.Err()
}
func pagination(r *http.Request) (int, int) {
	p, _ := strconv.Atoi(r.URL.Query().Get("page"))
	size, _ := strconv.Atoi(r.URL.Query().Get("page_size"))
	if p < 1 {
		p = 1
	}
	if p > 1000000 {
		p = 1000000
	}
	if size < 1 || size > 100 {
		size = 20
	}
	return p, size
}
func (s *Service) page(w http.ResponseWriter, r *http.Request, selectSQL, fromWhere, order string, args []any) {
	var total int64
	if e := s.DB.QueryRowContext(r.Context(), "SELECT COUNT(*) "+fromWhere, args...).Scan(&total); e != nil {
		apiutil.Fail(w, e)
		return
	}
	p, size := pagination(r)
	items, e := query(r.Context(), s.DB, selectSQL+" "+fromWhere+" "+order+" LIMIT ? OFFSET ?", append(args, size, (p-1)*size)...)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	apiutil.JSON(w, 200, map[string]any{"items": items, "total": total, "page": p, "page_size": size})
}
func (s *Service) one(w http.ResponseWriter, r *http.Request, q string, args ...any) {
	items, e := query(r.Context(), s.DB, q, args...)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	if len(items) == 0 {
		apiutil.Fail(w, apiutil.ErrNotFound)
		return
	}
	apiutil.JSON(w, 200, items[0])
}
func reason(r *http.Request) (string, error) {
	var in struct{ Reason string }
	if e := apiutil.Decode(r, &in); e != nil {
		return "", e
	}
	in.Reason = strings.TrimSpace(in.Reason)
	if len([]rune(in.Reason)) < 2 || len([]rune(in.Reason)) > 300 {
		return "", apiutil.Err(400, "reason_required", "请填写 2–300 字的操作理由")
	}
	return in.Reason, nil
}
func (s *Service) overview(w http.ResponseWriter, r *http.Request) {
	out := map[string]any{"started_at": s.Started, "uptime_seconds": int64(time.Since(s.Started).Seconds()), "relayed_bytes_since_start": transfers.RelayedBytes.Load(), "count_timezone": "UTC"}
	queries := map[string]string{"users": "SELECT COUNT(*) FROM users", "disabled_users": "SELECT COUNT(*) FROM users WHERE disabled_at IS NOT NULL", "devices": "SELECT COUNT(*) FROM devices WHERE revoked_at IS NULL", "messages": "SELECT COUNT(*) FROM messages", "messages_today": "SELECT COUNT(*) FROM messages WHERE created_at>=UTC_DATE()", "pending_messages": "SELECT COUNT(*) FROM messages WHERE delivered_at IS NULL", "transfers": "SELECT COUNT(*) FROM transfer_tasks", "failed_transfers_today": "SELECT COUNT(*) FROM transfer_tasks WHERE status='FAILED' AND created_at>=UTC_DATE()"}
	for name, q := range queries {
		var v int64
		if e := s.DB.QueryRowContext(r.Context(), q).Scan(&v); e != nil {
			apiutil.Fail(w, e)
			return
		}
		out[name] = v
	}
	out["online_devices"] = s.Hub.OnlineCount()
	out["database_healthy"] = true
	groups, e := query(r.Context(), s.DB, `SELECT status,mode,COUNT(*) AS count FROM transfer_tasks GROUP BY status,mode`)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	out["transfer_groups"] = groups
	trend := []map[string]any{}
	for i := 6; i >= 0; i-- {
		start := time.Now().UTC().Truncate(24*time.Hour).AddDate(0, 0, -i)
		end := start.AddDate(0, 0, 1)
		row := map[string]any{"date": start.Format("2006-01-02")}
		for _, table := range []string{"users", "messages", "transfer_tasks"} {
			var n int64
			if e := s.DB.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM "+table+" WHERE created_at>=? AND created_at<?", start, end).Scan(&n); e != nil {
				apiutil.Fail(w, e)
				return
			}
			row[table] = n
		}
		trend = append(trend, row)
	}
	out["trend"] = trend
	apiutil.JSON(w, 200, out)
}
func (s *Service) users(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	where := "FROM users u WHERE 1=1"
	args := []any{}
	if v := q.Get("q"); v != "" {
		where += " AND (u.username LIKE ? OR CAST(u.id AS CHAR)=?)"
		args = append(args, "%"+v+"%", v)
	}
	if q.Get("status") == "disabled" {
		where += " AND u.disabled_at IS NOT NULL"
	}
	if q.Get("status") == "active" {
		where += " AND u.disabled_at IS NULL"
	}
	s.page(w, r, `SELECT u.id,u.username,u.created_at,u.disabled_at,(SELECT COUNT(*) FROM devices d WHERE d.user_id=u.id AND d.revoked_at IS NULL) AS device_count`, where, "ORDER BY u.id DESC", args)
}
func (s *Service) userDetail(w http.ResponseWriter, r *http.Request) {
	items, e := query(r.Context(), s.DB, `SELECT id,username,created_at,disabled_at FROM users WHERE id=?`, r.PathValue("id"))
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	if len(items) == 0 {
		apiutil.Fail(w, apiutil.ErrNotFound)
		return
	}
	devices, e := query(r.Context(), s.DB, deviceSelect+` FROM devices d JOIN users u ON u.id=d.user_id WHERE u.id=? ORDER BY d.created_at DESC`, r.PathValue("id"))
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	s.presence(devices)
	items[0]["devices"] = devices
	apiutil.JSON(w, 200, items[0])
}

const deviceSelect = `SELECT d.id,d.user_id,u.username,d.name,d.device_type,d.os_version,d.app_version,d.status,d.created_at,d.last_seen_at,d.revoked_at`

func (s *Service) presence(items []map[string]any) {
	for _, d := range items {
		d["online"] = s.Hub.Online(fmt.Sprint(d["id"]))
	}
}
func (s *Service) devices(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	where := `FROM devices d JOIN users u ON u.id=d.user_id WHERE 1=1`
	args := []any{}
	if v := q.Get("q"); v != "" {
		where += " AND (d.name LIKE ? OR d.id=? OR u.username LIKE ?)"
		args = append(args, "%"+v+"%", v, "%"+v+"%")
	}
	for _, f := range []struct{ param, col string }{{"user_id", "d.user_id"}, {"type", "d.device_type"}} {
		if v := q.Get(f.param); v != "" {
			where += " AND " + f.col + "=?"
			args = append(args, v)
		}
	}
	switch q.Get("status") {
	case "revoked":
		where += " AND d.revoked_at IS NOT NULL"
	case "online":
		where += " AND d.status='online' AND d.revoked_at IS NULL"
	case "offline":
		where += " AND d.status<>'online' AND d.revoked_at IS NULL"
	}
	s.page(w, r, deviceSelect, where, "ORDER BY d.created_at DESC,d.id", args)
}
func (s *Service) deviceDetail(w http.ResponseWriter, r *http.Request) {
	items, e := query(r.Context(), s.DB, deviceSelect+` FROM devices d JOIN users u ON u.id=d.user_id WHERE d.id=?`, r.PathValue("id"))
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	if len(items) == 0 {
		apiutil.Fail(w, apiutil.ErrNotFound)
		return
	}
	s.presence(items)
	apiutil.JSON(w, 200, items[0])
}

const transferSelect = `SELECT t.id,t.user_id,u.username,t.sender_device_id,t.receiver_device_id,t.file_name,t.size,t.status,t.mode,t.error,t.created_at,t.updated_at,TIMESTAMPDIFF(SECOND,t.created_at,IF(t.status IN ('COMPLETED','REJECTED','CANCELLED','FAILED','EXPIRED'),t.updated_at,UTC_TIMESTAMP(3))) AS elapsed_seconds`

func (s *Service) transferList(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	where := `FROM transfer_tasks t JOIN users u ON u.id=t.user_id WHERE 1=1`
	args := []any{}
	if v := q.Get("q"); v != "" {
		where += " AND (t.file_name LIKE ? OR t.id=?)"
		args = append(args, "%"+v+"%", v)
	}
	for _, f := range []struct{ param, col string }{{"user_id", "t.user_id"}, {"status", "t.status"}, {"mode", "t.mode"}} {
		if v := q.Get(f.param); v != "" {
			where += " AND " + f.col + "=?"
			args = append(args, v)
		}
	}
	for _, param := range []string{"from", "to"} {
		if v := q.Get(param); v != "" {
			date, e := time.Parse("2006-01-02", v)
			if e != nil {
				apiutil.Fail(w, apiutil.Err(400, "invalid_date", "日期格式应为 YYYY-MM-DD"))
				return
			}
			if param == "from" {
				where += " AND t.created_at>=?"
			} else {
				where += " AND t.created_at<?"
				date = date.AddDate(0, 0, 1)
			}
			args = append(args, date)
		}
	}
	s.page(w, r, transferSelect, where, "ORDER BY t.created_at DESC,t.id", args)
}
func (s *Service) transferDetail(w http.ResponseWriter, r *http.Request) {
	s.one(w, r, transferSelect+` FROM transfer_tasks t JOIN users u ON u.id=t.user_id WHERE t.id=?`, r.PathValue("id"))
}
func (s *Service) auditList(w http.ResponseWriter, r *http.Request) {
	where := "FROM admin_audit WHERE 1=1"
	args := []any{}
	for _, name := range []string{"action", "actor", "target"} {
		if v := r.URL.Query().Get(name); v != "" {
			where += " AND " + name + " LIKE ?"
			args = append(args, "%"+v+"%")
		}
	}
	s.page(w, r, `SELECT id,actor,action,target,reason,result,source_ip,created_at`, where, "ORDER BY id DESC", args)
}
func (s *Service) userAction(w http.ResponseWriter, r *http.Request) {
	why, e := reason(r)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	action := r.PathValue("action")
	if action != "disable" && action != "enable" && action != "revoke" {
		apiutil.Fail(w, apiutil.ErrNotFound)
		return
	}
	id := r.PathValue("id")
	tx, e := s.DB.BeginTx(r.Context(), nil)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	defer tx.Rollback()
	var uid uint64
	e = tx.QueryRowContext(r.Context(), `SELECT id FROM users WHERE id=? FOR UPDATE`, id).Scan(&uid)
	if e == sql.ErrNoRows {
		apiutil.Fail(w, apiutil.ErrNotFound)
		return
	}
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	devices, e := query(r.Context(), tx, `SELECT id FROM devices WHERE user_id=?`, uid)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	if action == "enable" {
		var queued int
		e = tx.QueryRowContext(r.Context(), `SELECT COUNT(*) FROM admin_jobs WHERE JSON_UNQUOTE(JSON_EXTRACT(spec_json,'$.kind'))='user_delete' AND JSON_EXTRACT(spec_json,'$.user_id')=? AND status<>'COMPLETED'`, uid).Scan(&queued)
		if e != nil {
			apiutil.Fail(w, e)
			return
		}
		if queued > 0 {
			apiutil.Fail(w, apiutil.Err(409, "deletion_pending", "账号正在注销或有未完成注销任务，不能解封"))
			return
		}
	}
	var cancelled []string
	switch action {
	case "disable":
		_, e = tx.ExecContext(r.Context(), `UPDATE users SET disabled_at=UTC_TIMESTAMP(3) WHERE id=?`, uid)
	case "enable":
		_, e = tx.ExecContext(r.Context(), `UPDATE users SET disabled_at=NULL WHERE id=?`, uid)
	}
	if e == nil && action != "enable" {
		_, e = tx.ExecContext(r.Context(), `UPDATE device_sessions s JOIN devices d ON d.id=s.device_id SET s.revoked_at=UTC_TIMESTAMP(3) WHERE d.user_id=? AND s.revoked_at IS NULL`, uid)
	}
	if e == nil && action != "enable" {
		cancelled, e = cancelTasks(r.Context(), tx, "user_id=?", uid)
	}
	if e == nil {
		e = audit.Write(r.Context(), tx, s.event(r, "user."+action, id, why, "success"))
	}
	if e == nil {
		e = tx.Commit()
	}
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	for _, id := range cancelled {
		if s.AbortTransfer != nil {
			s.AbortTransfer(id)
		}
	}
	if action != "enable" {
		for _, d := range devices {
			s.Hub.Disconnect(fmt.Sprint(d["id"]))
		}
	}
	w.WriteHeader(204)
}
func (s *Service) deviceAction(w http.ResponseWriter, r *http.Request) {
	why, e := reason(r)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	action := r.PathValue("action")
	if action != "disconnect" && action != "remove" {
		apiutil.Fail(w, apiutil.ErrNotFound)
		return
	}
	id := r.PathValue("id")
	tx, e := s.DB.BeginTx(r.Context(), nil)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	defer tx.Rollback()
	var exists int
	e = tx.QueryRowContext(r.Context(), `SELECT 1 FROM devices WHERE id=? AND revoked_at IS NULL FOR UPDATE`, id).Scan(&exists)
	if e == sql.ErrNoRows {
		apiutil.Fail(w, apiutil.ErrNotFound)
		return
	}
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	if action == "remove" {
		_, e = tx.ExecContext(r.Context(), `UPDATE devices SET revoked_at=UTC_TIMESTAMP(3),status='revoked' WHERE id=?`, id)
	}
	if e == nil {
		_, e = tx.ExecContext(r.Context(), `UPDATE device_sessions SET revoked_at=UTC_TIMESTAMP(3) WHERE device_id=? AND revoked_at IS NULL`, id)
	}
	var cancelled []string
	if e == nil {
		cancelled, e = cancelTasks(r.Context(), tx, "(sender_device_id=? OR receiver_device_id=?)", id, id)
	}
	if e == nil {
		e = audit.Write(r.Context(), tx, s.event(r, "device."+action, id, why, "success"))
	}
	if e == nil {
		e = tx.Commit()
	}
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	for _, task := range cancelled {
		if s.AbortTransfer != nil {
			s.AbortTransfer(task)
		}
	}
	s.Hub.Disconnect(id)
	w.WriteHeader(204)
}
func (s *Service) cancelTransfer(w http.ResponseWriter, r *http.Request) {
	why, e := reason(r)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	id := r.PathValue("id")
	tx, e := s.DB.BeginTx(r.Context(), nil)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	defer tx.Rollback()
	var sender, receiver, status string
	e = tx.QueryRowContext(r.Context(), `SELECT sender_device_id,receiver_device_id,status FROM transfer_tasks WHERE id=? FOR UPDATE`, id).Scan(&sender, &receiver, &status)
	if e == sql.ErrNoRows {
		apiutil.Fail(w, apiutil.ErrNotFound)
		return
	}
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	if !active(status) {
		apiutil.Fail(w, apiutil.Err(409, "terminal_task", "任务已结束，不能取消"))
		return
	}
	_, e = tx.ExecContext(r.Context(), `UPDATE transfer_tasks SET status='CANCELLED',error='admin_cancelled',updated_at=UTC_TIMESTAMP(3) WHERE id=? AND status=?`, id, status)
	if e == nil {
		e = audit.Write(r.Context(), tx, s.event(r, "transfer.cancel", id, why, "success"))
	}
	if e == nil {
		e = tx.Commit()
	}
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	if s.AbortTransfer != nil {
		s.AbortTransfer(id)
	} else {
		payload := map[string]any{"id": id, "status": "CANCELLED", "error": "admin_cancelled"}
		s.Hub.Send(sender, "transfer.cancel", payload)
		s.Hub.Send(receiver, "transfer.cancel", payload)
	}
	w.WriteHeader(204)
}
func active(status string) bool {
	return status == "CREATED" || status == "WAITING_ACCEPT" || status == "ACCEPTED" || status == "TRANSFERRING" || status == "VERIFYING"
}

func cancelTasks(ctx context.Context, tx *sql.Tx, where string, args ...any) ([]string, error) {
	rows, e := query(ctx, tx, "SELECT id FROM transfer_tasks WHERE "+where+" AND NOT ("+terminalSQL+") FOR UPDATE", args...)
	if e != nil {
		return nil, e
	}
	ids := []string{}
	for _, row := range rows {
		ids = append(ids, fmt.Sprint(row["id"]))
	}
	_, e = tx.ExecContext(ctx, "UPDATE transfer_tasks SET status='CANCELLED',error='admin_revoked',updated_at=UTC_TIMESTAMP(3) WHERE "+where+" AND NOT ("+terminalSQL+")", args...)
	return ids, e
}
