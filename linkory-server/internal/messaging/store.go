package messaging

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/linkory/linkory-server/internal/apiutil"
)

const MaxContentBytes = 64 * 1024

type Message struct {
	ID          string     `json:"id"`
	ConvID      string     `json:"conversation_id"`
	ClientMsgID string     `json:"client_msg_id"`
	From        string     `json:"from_device_id"`
	To          string     `json:"to_device_id"`
	Type        string     `json:"type"`
	Content     string     `json:"content"`
	CreatedAt   time.Time  `json:"created_at"`
	DeliveredAt *time.Time `json:"delivered_at"`
}

type Store struct{ DB *sql.DB }

func pair(a, b string) (string, string) {
	if a < b {
		return a, b
	}
	return b, a
}

// liveDeviceOwner returns the owner of a non-revoked device.
func (s *Store) liveDeviceOwner(ctx context.Context, id string) (uint64, error) {
	var uid uint64
	err := s.DB.QueryRowContext(ctx, `SELECT user_id FROM devices WHERE id=? AND revoked_at IS NULL`, id).Scan(&uid)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, apiutil.ErrNotFound
	}
	return uid, err
}

// Save persists a message idempotently on (sender, client_msg_id). dup is true when it already existed.
func (s *Store) Save(ctx context.Context, userID uint64, from, to, clientID, typ, content string) (m *Message, dup bool, err error) {
	if typ != "text" && typ != "clipboard" {
		return nil, false, apiutil.Err(400, "invalid_type", "type must be text or clipboard")
	}
	if _, perr := uuid.Parse(clientID); perr != nil {
		return nil, false, apiutil.Err(400, "invalid_client_msg_id", "client_msg_id must be a UUID")
	}
	if content == "" || len(content) > MaxContentBytes {
		return nil, false, apiutil.Err(400, "invalid_content", "content must be 1..65536 bytes")
	}
	if from == to {
		return nil, false, apiutil.Err(400, "invalid_target", "cannot send to the same device")
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, false, err
	}
	defer tx.Rollback()
	var liveUser uint64
	if e := tx.QueryRowContext(ctx, `SELECT id FROM users WHERE id=? AND disabled_at IS NULL FOR SHARE`, userID).Scan(&liveUser); e != nil {
		return nil, false, apiutil.ErrForbidden
	}
	owner, err := s.liveDeviceOwner(ctx, to)
	if err != nil || owner != userID {
		return nil, false, apiutil.ErrNotFound // do not reveal other accounts' devices
	}
	if existing, e := s.byClientID(ctx, from, clientID); e == nil {
		return existing, true, nil
	}
	lo, hi := pair(from, to)
	convID := uuid.NewString()
	if _, err = tx.ExecContext(ctx, `INSERT IGNORE INTO conversations(id,user_id,device_lo,device_hi) VALUES(?,?,?,?)`, convID, userID, lo, hi); err != nil {
		return nil, false, err
	}
	if err = tx.QueryRowContext(ctx, `SELECT id FROM conversations WHERE device_lo=? AND device_hi=?`, lo, hi).Scan(&convID); err != nil {
		return nil, false, err
	}
	id := uuid.NewString()
	_, err = tx.ExecContext(ctx, `INSERT INTO messages(id,conversation_id,client_msg_id,sender_device_id,receiver_device_id,msg_type,content) VALUES(?,?,?,?,?,?,?)`,
		id, convID, clientID, from, to, typ, content)
	if err != nil {
		if existing, e := s.byClientID(ctx, from, clientID); e == nil { // lost an idempotency race
			return existing, true, nil
		}
		return nil, false, err
	}
	_, _ = tx.ExecContext(ctx, `UPDATE conversations SET updated_at=CURRENT_TIMESTAMP(3) WHERE id=?`, convID)
	if err = tx.Commit(); err != nil {
		return nil, false, err
	}
	m, err = s.get(ctx, id)
	return m, false, err
}

const msgCols = `id,conversation_id,client_msg_id,sender_device_id,receiver_device_id,msg_type,content,created_at,delivered_at`

func scan(row interface{ Scan(...any) error }) (*Message, error) {
	var m Message
	var d sql.NullTime
	if err := row.Scan(&m.ID, &m.ConvID, &m.ClientMsgID, &m.From, &m.To, &m.Type, &m.Content, &m.CreatedAt, &d); err != nil {
		return nil, err
	}
	if d.Valid {
		m.DeliveredAt = &d.Time
	}
	return &m, nil
}

func (s *Store) get(ctx context.Context, id string) (*Message, error) {
	return scan(s.DB.QueryRowContext(ctx, `SELECT `+msgCols+` FROM messages WHERE id=?`, id))
}

func (s *Store) byClientID(ctx context.Context, from, clientID string) (*Message, error) {
	return scan(s.DB.QueryRowContext(ctx, `SELECT `+msgCols+` FROM messages WHERE sender_device_id=? AND client_msg_id=?`, from, clientID))
}

// MarkDelivered flags a message as delivered; only the receiver may do so. Returns the message if newly marked.
func (s *Store) MarkDelivered(ctx context.Context, msgID, receiver string) (*Message, error) {
	res, err := s.DB.ExecContext(ctx, `UPDATE messages SET delivered_at=CURRENT_TIMESTAMP(3) WHERE id=? AND receiver_device_id=? AND delivered_at IS NULL`, msgID, receiver)
	if err != nil {
		return nil, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return nil, nil
	}
	return s.get(ctx, msgID)
}

func (s *Store) Pending(ctx context.Context, receiver string, ttl time.Duration) ([]*Message, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT `+msgCols+` FROM messages WHERE receiver_device_id=? AND delivered_at IS NULL AND created_at > ? ORDER BY created_at LIMIT 1000`,
		receiver, time.Now().UTC().Add(-ttl))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Message
	for rows.Next() {
		m, err := scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// History returns messages between the calling device and peer, newest first, optionally before a timestamp.
func (s *Store) History(ctx context.Context, userID uint64, self, peer string, before time.Time, limit int) ([]*Message, error) {
	if owner, err := s.liveDeviceOwner(ctx, peer); err != nil || owner != userID {
		return nil, apiutil.ErrNotFound
	}
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	if before.IsZero() {
		before = time.Now().UTC().Add(time.Minute)
	}
	lo, hi := pair(self, peer)
	rows, err := s.DB.QueryContext(ctx, `SELECT `+msgCols+` FROM messages m WHERE conversation_id=(SELECT id FROM conversations WHERE device_lo=? AND device_hi=?) AND created_at < ? ORDER BY created_at DESC LIMIT ?`,
		lo, hi, before.UTC(), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []*Message{}
	for rows.Next() {
		m, err := scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

type Conversation struct {
	ID        string    `json:"id"`
	PeerID    string    `json:"peer_device_id"`
	UpdatedAt time.Time `json:"updated_at"`
}

func (s *Store) Conversations(ctx context.Context, userID uint64, self string) ([]Conversation, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT id, IF(device_lo=?, device_hi, device_lo), updated_at FROM conversations
		WHERE user_id=? AND (device_lo=? OR device_hi=?) ORDER BY updated_at DESC`, self, userID, self, self)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Conversation{}
	for rows.Next() {
		var c Conversation
		if err := rows.Scan(&c.ID, &c.PeerID, &c.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *Store) PurgeExpired(ctx context.Context, ttl time.Duration) {
	_, _ = s.DB.ExecContext(ctx, `DELETE FROM messages WHERE delivered_at IS NULL AND created_at < ?`, time.Now().UTC().Add(-ttl))
}
