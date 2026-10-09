// Package transfers implements the file task state machine and the streaming relay.
//
// CREATED → WAITING_ACCEPT → ACCEPTED → TRANSFERRING → VERIFYING → COMPLETED
// with terminal REJECTED / CANCELLED / FAILED / EXPIRED. Every transition is a guarded
// UPDATE (WHERE status IN (...)) so concurrent actors cannot skip or revisit states.
package transfers

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/linkory/linkory-server/internal/apiutil"
)

const (
	Created       = "CREATED"
	WaitingAccept = "WAITING_ACCEPT"
	Accepted      = "ACCEPTED"
	Transferring  = "TRANSFERRING"
	Verifying     = "VERIFYING"
	Completed     = "COMPLETED"
	Rejected      = "REJECTED"
	Cancelled     = "CANCELLED"
	Failed        = "FAILED"
	Expired       = "EXPIRED"
	AcceptTimeout = 5 * time.Minute
	StartTimeout  = 5 * time.Minute
	StaleTransfer = 30 * time.Minute
)

// LANInfo is where a device listens for direct (same-network) transfers.
type LANInfo struct {
	Addrs []string `json:"addrs"`
	Port  int      `json:"port"`
}

type Task struct {
	ID       string `json:"id"`
	Sender   string `json:"sender_device_id"`
	Receiver string `json:"receiver_device_id"`
	FileName string `json:"file_name"`
	Size     uint64 `json:"size"`
	SHA256   string `json:"sha256"`
	Status   string `json:"status"`
	Mode     string `json:"mode"` // relay | lan: which path actually carried the file
	Error    string `json:"error"`
	// LANSecret is a per-task random key shared only with the two participants; it authenticates
	// and encrypts the direct channel (never sent to anyone else).
	LANSecret   string    `json:"lan_secret,omitempty"`
	ReceiverLAN *LANInfo  `json:"receiver_lan,omitempty"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
	UserID      uint64    `json:"-"`
}

type Service struct {
	DB       *sql.DB
	MaxBytes uint64
}

var sha256Re = regexp.MustCompile(`^[0-9a-f]{64}$`)

const cols = `id,user_id,sender_device_id,receiver_device_id,file_name,size,sha256,status,mode,lan_secret,error,created_at,updated_at`

func scan(r interface{ Scan(...any) error }) (*Task, error) {
	var t Task
	err := r.Scan(&t.ID, &t.UserID, &t.Sender, &t.Receiver, &t.FileName, &t.Size, &t.SHA256, &t.Status, &t.Mode, &t.LANSecret, &t.Error, &t.CreatedAt, &t.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, apiutil.ErrNotFound
	}
	return &t, err
}

// Get returns the task only to its two participants.
func (s *Service) Get(ctx context.Context, id, device string) (*Task, error) {
	t, err := scan(s.DB.QueryRowContext(ctx, `SELECT `+cols+` FROM transfer_tasks WHERE id=?`, id))
	if err != nil {
		return nil, err
	}
	if t.Sender != device && t.Receiver != device {
		return nil, apiutil.ErrNotFound
	}
	return t, nil
}

func (s *Service) List(ctx context.Context, device string, limit int) ([]*Task, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	rows, err := s.DB.QueryContext(ctx, `SELECT `+cols+` FROM transfer_tasks WHERE sender_device_id=? OR receiver_device_id=? ORDER BY created_at DESC LIMIT ?`, device, device, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []*Task{}
	for rows.Next() {
		t, err := scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (s *Service) Create(ctx context.Context, userID uint64, sender, receiver, name string, size uint64, sum string, receiverOnline bool) (*Task, error) {
	name = strings.TrimSpace(name)
	if name == "" || len(name) > 255 || strings.ContainsAny(name, "/\\\x00") || name == "." || name == ".." {
		return nil, apiutil.Err(400, "invalid_file_name", "file_name must be a plain file name (1-255 bytes)")
	}
	if size == 0 || size > s.MaxBytes {
		return nil, apiutil.Err(400, "invalid_size", "size must be between 1 and the server limit")
	}
	sum = strings.ToLower(sum)
	if !sha256Re.MatchString(sum) {
		return nil, apiutil.Err(400, "invalid_sha256", "sha256 must be 64 hex chars")
	}
	if sender == receiver {
		return nil, apiutil.Err(400, "invalid_target", "cannot send to the same device")
	}
	var owner uint64
	err := s.DB.QueryRowContext(ctx, `SELECT user_id FROM devices WHERE id=? AND revoked_at IS NULL`, receiver).Scan(&owner)
	if err != nil || owner != userID {
		return nil, apiutil.ErrNotFound
	}
	if !receiverOnline { // PRD 4.8: offline files are not supported in V1.0
		return nil, apiutil.Err(409, "receiver_offline", "target device is offline; offline file transfer is not supported")
	}
	id := uuid.NewString()
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return nil, err
	}
	if _, err := s.DB.ExecContext(ctx, `INSERT INTO transfer_tasks(id,user_id,sender_device_id,receiver_device_id,file_name,size,sha256,status,lan_secret) VALUES(?,?,?,?,?,?,?,?,?)`,
		id, userID, sender, receiver, name, size, sum, WaitingAccept, hex.EncodeToString(secret)); err != nil {
		return nil, err
	}
	return s.Get(ctx, id, sender)
}

// Transition atomically moves a task from any of `from` to `to`. ok=false means the task was
// not in an allowed state (someone else already moved it).
func (s *Service) Transition(ctx context.Context, id string, to string, errMsg string, from ...string) (bool, error) {
	ph := strings.TrimSuffix(strings.Repeat("?,", len(from)), ",")
	args := []any{to, errMsg, id}
	for _, f := range from {
		args = append(args, f)
	}
	res, err := s.DB.ExecContext(ctx, `UPDATE transfer_tasks SET status=?, error=? WHERE id=? AND status IN (`+ph+`)`, args...)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// SetMode records which path carried the file.
func (s *Service) SetMode(ctx context.Context, id, mode string) {
	_, _ = s.DB.ExecContext(ctx, `UPDATE transfer_tasks SET mode=? WHERE id=?`, mode, id)
}

// Sweep expires tasks nobody acted on and fails transfers that stalled (e.g. server restart).
func (s *Service) Sweep(ctx context.Context) []*Task {
	now := time.Now().UTC()
	var changed []*Task
	for _, r := range []struct {
		from, to string
		age      time.Duration
	}{
		{WaitingAccept, Expired, AcceptTimeout},
		{Accepted, Expired, StartTimeout},
		{Transferring, Failed, StaleTransfer},
		{Verifying, Failed, StaleTransfer},
	} {
		rows, err := s.DB.QueryContext(ctx, `SELECT `+cols+` FROM transfer_tasks WHERE status=? AND updated_at < ?`, r.from, now.Add(-r.age))
		if err != nil {
			continue
		}
		var ts []*Task
		for rows.Next() {
			if t, err := scan(rows); err == nil {
				ts = append(ts, t)
			}
		}
		rows.Close()
		for _, t := range ts {
			if ok, _ := s.Transition(ctx, t.ID, r.to, "timeout", r.from); ok {
				t.Status = r.to
				changed = append(changed, t)
			}
		}
	}
	return changed
}
