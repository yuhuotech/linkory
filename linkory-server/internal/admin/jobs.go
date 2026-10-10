package admin

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/linkory/linkory-server/internal/apiutil"
	"github.com/linkory/linkory-server/internal/audit"
)

type Policy struct {
	OfflineDays   int `json:"offline_days"`
	DeliveredDays int `json:"delivered_days"`
	TransferDays  int `json:"transfer_days"`
}
type Spec struct {
	Kind   string    `json:"kind"`
	UserID uint64    `json:"user_id"`
	Cutoff time.Time `json:"cutoff"`
	Policy Policy    `json:"policy"`
}

func (s *Service) Policy(ctx context.Context) (Policy, error) {
	p := Policy{}
	_, e := s.DB.ExecContext(ctx, `INSERT IGNORE INTO admin_policy(id,offline_days) VALUES(1,?)`, s.DefaultOfflineDays)
	if e != nil {
		return p, e
	}
	e = s.DB.QueryRowContext(ctx, `SELECT offline_days,delivered_days,transfer_days FROM admin_policy WHERE id=1`).Scan(&p.OfflineDays, &p.DeliveredDays, &p.TransferDays)
	return p, e
}
func (s *Service) getPolicy(w http.ResponseWriter, r *http.Request) {
	p, e := s.Policy(r.Context())
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	apiutil.JSON(w, 200, p)
}
func (s *Service) setPolicy(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Policy
		Reason string
	}
	if e := apiutil.Decode(r, &in); e != nil {
		apiutil.Fail(w, e)
		return
	}
	if in.OfflineDays < 1 || in.OfflineDays > 365 || in.DeliveredDays < 0 || in.DeliveredDays > 3650 || in.TransferDays < 0 || in.TransferDays > 3650 || len([]rune(strings.TrimSpace(in.Reason))) < 2 || len([]rune(in.Reason)) > 300 {
		apiutil.Fail(w, apiutil.Err(400, "invalid_policy", "保留天数或操作理由不合法"))
		return
	}
	if _, e := s.Policy(r.Context()); e != nil {
		apiutil.Fail(w, e)
		return
	}
	tx, e := s.DB.BeginTx(r.Context(), nil)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	defer tx.Rollback()
	_, e = tx.ExecContext(r.Context(), `UPDATE admin_policy SET offline_days=?,delivered_days=?,transfer_days=?,updated_at=UTC_TIMESTAMP(3) WHERE id=1`, in.OfflineDays, in.DeliveredDays, in.TransferDays)
	if e == nil {
		e = audit.Write(r.Context(), tx, s.event(r, "retention.update", "policy", in.Reason, "success"))
	}
	if e == nil {
		e = tx.Commit()
	}
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	apiutil.JSON(w, 200, in.Policy)
}

const terminalSQL = `status IN ('COMPLETED','REJECTED','CANCELLED','FAILED','EXPIRED')`

func predicates(spec Spec) (string, []any, string, []any) {
	if spec.Kind == "retention" {
		mw := "(delivered_at IS NULL AND created_at<?)"
		ma := []any{spec.Cutoff.AddDate(0, 0, -spec.Policy.OfflineDays)}
		if spec.Policy.DeliveredDays > 0 {
			mw += " OR (delivered_at IS NOT NULL AND created_at<?)"
			ma = append(ma, spec.Cutoff.AddDate(0, 0, -spec.Policy.DeliveredDays))
		}
		if spec.Policy.TransferDays > 0 {
			return "(" + mw + ")", ma, terminalSQL + " AND created_at<?", []any{spec.Cutoff.AddDate(0, 0, -spec.Policy.TransferDays)}
		}
		return "(" + mw + ")", ma, "1=0", nil
	}
	mw := "conversation_id IN (SELECT id FROM conversations WHERE user_id=?)"
	ma := []any{spec.UserID}
	tw := "user_id=? AND " + terminalSQL
	ta := []any{spec.UserID}
	if spec.Kind != "user_delete" {
		mw += " AND created_at<?"
		ma = append(ma, spec.Cutoff)
		tw += " AND created_at<?"
		ta = append(ta, spec.Cutoff)
	}
	if spec.Kind == "user_transfers" {
		mw = "1=0"
		ma = nil
	}
	if spec.Kind == "user_messages" {
		tw = "1=0"
		ta = nil
	}
	return mw, ma, tw, ta
}
func (s *Service) counts(ctx context.Context, spec Spec) (map[string]int64, error) {
	mw, ma, tw, ta := predicates(spec)
	out := map[string]int64{"messages": 0, "transfer_tasks": 0, "devices": 0, "users": 0}
	for _, v := range []struct {
		name, where string
		args        []any
	}{{"messages", mw, ma}, {"transfer_tasks", tw, ta}} {
		var n int64
		e := s.DB.QueryRowContext(ctx, "SELECT COUNT(*) FROM "+v.name+" WHERE "+v.where, v.args...).Scan(&n)
		if e != nil {
			return nil, e
		}
		out[v.name] = n
	}
	if spec.Kind == "user_delete" {
		var n int64
		e := s.DB.QueryRowContext(ctx, `SELECT COUNT(*) FROM devices WHERE user_id=?`, spec.UserID).Scan(&n)
		if e != nil {
			return nil, e
		}
		out["devices"] = n
		out["users"] = 1
	}
	return out, nil
}
func (s *Service) checkUser(ctx context.Context, spec Spec) error {
	if spec.Kind == "retention" {
		return nil
	}
	var n int
	e := s.DB.QueryRowContext(ctx, `SELECT COUNT(*) FROM users WHERE id=?`, spec.UserID).Scan(&n)
	if e != nil {
		return e
	}
	if n == 0 {
		return apiutil.ErrNotFound
	}
	if spec.Kind == "user_delete" {
		e = s.DB.QueryRowContext(ctx, `SELECT COUNT(*) FROM transfer_tasks WHERE user_id=? AND NOT (`+terminalSQL+`)`, spec.UserID).Scan(&n)
		if e != nil {
			return e
		}
		if n > 0 {
			return apiutil.Err(409, "active_transfers", "该账号存在活动传输，请先取消或等待任务结束再注销")
		}
	}
	return nil
}
func (s *Service) preview(w http.ResponseWriter, r *http.Request) {
	var spec Spec
	if e := apiutil.Decode(r, &spec); e != nil {
		apiutil.Fail(w, e)
		return
	}
	switch spec.Kind {
	case "retention", "user_messages", "user_transfers", "user_delete":
	default:
		apiutil.Fail(w, apiutil.Err(400, "invalid_kind", "不支持的清理范围"))
		return
	}
	if spec.Kind != "retention" && spec.UserID == 0 {
		apiutil.Fail(w, apiutil.Err(400, "user_required", "请选择账号"))
		return
	}
	spec.Cutoff = time.Now().UTC()
	p, e := s.Policy(r.Context())
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	spec.Policy = p
	if e = s.checkUser(r.Context(), spec); e != nil {
		apiutil.Fail(w, e)
		return
	}
	counts, e := s.counts(r.Context(), spec)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	id := randomToken()
	raw, _ := json.Marshal(spec)
	cr, _ := json.Marshal(counts)
	exp := time.Now().UTC().Add(10 * time.Minute)
	_, e = s.DB.ExecContext(r.Context(), `INSERT INTO admin_previews(id,admin_id,spec_json,counts_json,expires_at) VALUES(?,?,?,?,?)`, id, actor(r).ID, raw, cr, exp)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	apiutil.JSON(w, 200, map[string]any{"preview_id": id, "spec": spec, "counts": counts, "expires_at": exp})
}
func (s *Service) createJob(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Preview string `json:"preview_id"`
		Confirm string
		Reason  string
	}
	if e := apiutil.Decode(r, &in); e != nil {
		apiutil.Fail(w, e)
		return
	}
	if in.Confirm != "删除" || len([]rune(strings.TrimSpace(in.Reason))) < 2 || len([]rune(in.Reason)) > 300 {
		apiutil.Fail(w, apiutil.Err(400, "confirmation_required", "请确认删除并填写操作理由"))
		return
	}
	tx, e := s.DB.BeginTx(r.Context(), nil)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	defer tx.Rollback()
	var raw, counts []byte
	var exp time.Time
	var used sql.NullTime
	e = tx.QueryRowContext(r.Context(), `SELECT spec_json,counts_json,expires_at,consumed_at FROM admin_previews WHERE id=? AND admin_id=? FOR UPDATE`, in.Preview, actor(r).ID).Scan(&raw, &counts, &exp, &used)
	if e == sql.ErrNoRows || used.Valid || (!exp.IsZero() && time.Now().After(exp)) {
		apiutil.Fail(w, apiutil.Err(409, "preview_expired", "预览不存在、已使用或已过期，请重新预览"))
		return
	}
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	var spec Spec
	if e = json.Unmarshal(raw, &spec); e != nil {
		apiutil.Fail(w, e)
		return
	}
	if e = s.checkUser(r.Context(), spec); e != nil {
		apiutil.Fail(w, e)
		return
	}
	var deviceIDs []map[string]any
	if spec.Kind == "user_delete" {
		var uid uint64
		e = tx.QueryRowContext(r.Context(), `SELECT id FROM users WHERE id=? FOR UPDATE`, spec.UserID).Scan(&uid)
		if e == nil {
			var activeCount int
			e = tx.QueryRowContext(r.Context(), `SELECT COUNT(*) FROM transfer_tasks WHERE user_id=? AND NOT (`+terminalSQL+`)`, uid).Scan(&activeCount)
			if e == nil && activeCount > 0 {
				apiutil.Fail(w, apiutil.Err(409, "active_transfers", "有新活动传输，请重新预览"))
				return
			}
		}
		if e == nil {
			_, e = tx.ExecContext(r.Context(), `UPDATE users SET disabled_at=UTC_TIMESTAMP(3) WHERE id=?`, uid)
		}
		if e == nil {
			_, e = tx.ExecContext(r.Context(), `UPDATE device_sessions s JOIN devices d ON d.id=s.device_id SET s.revoked_at=UTC_TIMESTAMP(3) WHERE d.user_id=?`, uid)
		}
		if e == nil {
			deviceIDs, e = query(r.Context(), tx, `SELECT id FROM devices WHERE user_id=?`, uid)
		}
	}
	id := uuid.NewString()
	if e == nil {
		_, e = tx.ExecContext(r.Context(), `INSERT INTO admin_jobs(id,actor_id,actor,spec_json,counts_json,reason) VALUES(?,?,?,?,?,?)`, id, actor(r).ID, actor(r).Username, raw, counts, in.Reason)
	}
	if e == nil {
		_, e = tx.ExecContext(r.Context(), `UPDATE admin_previews SET consumed_at=UTC_TIMESTAMP(3) WHERE id=?`, in.Preview)
	}
	if e == nil {
		e = audit.Write(r.Context(), tx, s.event(r, "job.create", id, in.Reason, "queued"))
	}
	if e == nil {
		e = tx.Commit()
	}
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	for _, d := range deviceIDs {
		s.Hub.Disconnect(fmt.Sprint(d["id"]))
	}
	apiutil.JSON(w, 202, map[string]any{"id": id, "status": "QUEUED"})
}

const jobSelect = `SELECT id,actor,spec_json,counts_json,reason,status,deleted_rows,error,created_at,updated_at`

func (s *Service) jobs(w http.ResponseWriter, r *http.Request) {
	s.page(w, r, jobSelect, "FROM admin_jobs", "ORDER BY created_at DESC,id", nil)
}
func (s *Service) jobDetail(w http.ResponseWriter, r *http.Request) {
	s.one(w, r, jobSelect+` FROM admin_jobs WHERE id=?`, r.PathValue("id"))
}
func (s *Service) retryJob(w http.ResponseWriter, r *http.Request) {
	why, e := reason(r)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	tx, e := s.DB.BeginTx(r.Context(), nil)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	defer tx.Rollback()
	res, e := tx.ExecContext(r.Context(), `UPDATE admin_jobs SET status='QUEUED',error='',updated_at=UTC_TIMESTAMP(3) WHERE id=? AND status='FAILED'`, r.PathValue("id"))
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		apiutil.Fail(w, apiutil.Err(409, "not_failed", "仅失败任务可重试"))
		return
	}
	e = audit.Write(r.Context(), tx, s.event(r, "job.retry", r.PathValue("id"), why, "queued"))
	if e == nil {
		e = tx.Commit()
	}
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	w.WriteHeader(204)
}
func (s *Service) Run(ctx context.Context) {
	go s.runMonitor(ctx)
	// Deployment is single-instance; recover interrupted jobs instead of dropping them.
	_, _ = s.DB.ExecContext(ctx, `UPDATE admin_jobs SET status='QUEUED' WHERE status='RUNNING'`)
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	cleanup := time.NewTicker(time.Hour)
	defer cleanup.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-cleanup.C:
			s.QueueRetention(ctx)
			s.pruneFailures()
			_, _ = s.DB.ExecContext(ctx, `DELETE FROM admin_sessions WHERE expires_at<UTC_TIMESTAMP(3)`)
			_, _ = s.DB.ExecContext(ctx, `DELETE FROM admin_previews WHERE expires_at<UTC_TIMESTAMP(3)`)
		case <-tick.C:
			s.WorkOne(ctx)
		}
	}
}

// QueueRetention enqueues the policy-driven cleanup when something has aged out (hourly from Run; exported for tests).
func (s *Service) QueueRetention(ctx context.Context) {
	p, e := s.Policy(ctx)
	if e != nil {
		return
	}
	spec := Spec{Kind: "retention", Cutoff: time.Now().UTC(), Policy: p}
	counts, e := s.counts(ctx, spec)
	if e != nil || counts["messages"]+counts["transfer_tasks"] == 0 {
		return
	}
	var running int
	e = s.DB.QueryRowContext(ctx, `SELECT COUNT(*) FROM admin_jobs WHERE status IN ('QUEUED','RUNNING') AND JSON_UNQUOTE(JSON_EXTRACT(spec_json,'$.kind'))='retention'`).Scan(&running)
	if e != nil || running > 0 {
		return
	}
	raw, _ := json.Marshal(spec)
	cr, _ := json.Marshal(counts)
	id := uuid.NewString()
	tx, e := s.DB.BeginTx(ctx, nil)
	if e != nil {
		return
	}
	defer tx.Rollback()
	_, e = tx.ExecContext(ctx, `INSERT INTO admin_jobs(id,actor_id,actor,spec_json,counts_json,reason) VALUES(?,0,'system',?,?,'按数据保留策略定时清理')`, id, raw, cr)
	if e == nil {
		e = audit.Write(ctx, tx, audit.Event{Actor: "system", Action: "job.create", Target: id, Reason: "定时保留清理", Result: "queued"})
	}
	if e == nil {
		_ = tx.Commit()
	}
}

// WorkOne executes durable batches and is also callable by integration tests.
func (s *Service) WorkOne(ctx context.Context) {
	var id, actorName, why string
	var aid uint64
	var raw []byte
	tx, e := s.DB.BeginTx(ctx, nil)
	if e != nil {
		return
	}
	e = tx.QueryRowContext(ctx, `SELECT id,actor_id,actor,spec_json,reason FROM admin_jobs WHERE status='QUEUED' ORDER BY created_at,id LIMIT 1 FOR UPDATE SKIP LOCKED`).Scan(&id, &aid, &actorName, &raw, &why)
	if e != nil {
		_ = tx.Rollback()
		return
	}
	_, e = tx.ExecContext(ctx, `UPDATE admin_jobs SET status='RUNNING',updated_at=UTC_TIMESTAMP(3) WHERE id=?`, id)
	if e == nil {
		e = tx.Commit()
	} else {
		_ = tx.Rollback()
	}
	if e != nil {
		return
	}
	var spec Spec
	e = json.Unmarshal(raw, &spec)
	if e == nil {
		e = s.execute(ctx, id, spec)
	}
	if ctx.Err() != nil {
		return
	}
	status, result, errText := "COMPLETED", "success", ""
	if e != nil {
		status, result, errText = "FAILED", "failure", "数据库操作未完成，已完成批次保留；请检查服务状态后重试"
		if e.Error() == "active transfers" {
			errText = "账号仍有活动文件传输，已暂停注销；结束或取消任务后重试"
		}
	}
	tx, e2 := s.DB.BeginTx(ctx, nil)
	if e2 != nil {
		return
	}
	defer tx.Rollback()
	_, e2 = tx.ExecContext(ctx, `UPDATE admin_jobs SET status=?,error=?,updated_at=UTC_TIMESTAMP(3) WHERE id=?`, status, errText, id)
	if e2 == nil {
		e2 = audit.Write(ctx, tx, audit.Event{ActorID: aid, Actor: actorName, Action: "job.finish", Target: id, Reason: why, Result: result})
	}
	if e2 == nil {
		_ = tx.Commit()
	}
}
func (s *Service) execute(ctx context.Context, id string, spec Spec) error {
	if spec.Kind == "user_delete" {
		var n int
		if e := s.DB.QueryRowContext(ctx, `SELECT COUNT(*) FROM transfer_tasks WHERE user_id=? AND NOT (`+terminalSQL+`)`, spec.UserID).Scan(&n); e != nil {
			return e
		}
		if n > 0 {
			return fmt.Errorf("active transfers")
		}
	}
	mw, ma, tw, ta := predicates(spec)
	batches := []struct {
		table, where string
		args         []any
	}{{"messages", mw, ma}, {"transfer_tasks", tw, ta}}
	if spec.Kind == "user_delete" {
		batches = append(batches, struct {
			table, where string
			args         []any
		}{"conversations", "user_id=?", []any{spec.UserID}}, struct {
			table, where string
			args         []any
		}{"device_sessions", "device_id IN (SELECT id FROM devices WHERE user_id=?)", []any{spec.UserID}}, struct {
			table, where string
			args         []any
		}{"devices", "user_id=?", []any{spec.UserID}}, struct {
			table, where string
			args         []any
		}{"users", "id=? AND disabled_at IS NOT NULL", []any{spec.UserID}})
	}
	for _, b := range batches {
		for {
			if e := ctx.Err(); e != nil {
				return e
			}
			tx, e := s.DB.BeginTx(ctx, nil)
			if e != nil {
				return e
			}
			res, e := tx.ExecContext(ctx, "DELETE FROM "+b.table+" WHERE "+b.where+" LIMIT 500", b.args...)
			var n int64
			if e == nil {
				n, e = res.RowsAffected()
			}
			if e == nil {
				_, e = tx.ExecContext(ctx, `UPDATE admin_jobs SET deleted_rows=deleted_rows+?,updated_at=UTC_TIMESTAMP(3) WHERE id=?`, n, id)
			}
			if e == nil {
				e = tx.Commit()
			} else {
				_ = tx.Rollback()
			}
			if e != nil {
				return e
			}
			if n < 500 {
				break
			}
		}
	}
	return nil
}
