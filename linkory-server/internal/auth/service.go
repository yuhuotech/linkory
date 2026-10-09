package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/go-sql-driver/mysql"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"golang.org/x/crypto/argon2"

	"github.com/linkory/linkory-server/internal/apiutil"
)

type Service struct {
	DB         *sql.DB
	Secret     []byte
	AccessTTL  time.Duration
	RefreshTTL time.Duration

	// OnRevoke is called with the devices whose sessions were just revoked (e.g. after a password
	// change) so live connections can be dropped.
	OnRevoke func(deviceIDs []string)

	mu       sync.Mutex
	failures map[string][]time.Time
}

func NewService(db *sql.DB, secret []byte, access, refresh time.Duration) *Service {
	return &Service{DB: db, Secret: secret, AccessTTL: access, RefreshTTL: refresh, failures: map[string][]time.Time{}}
}

type DeviceInfo struct {
	DeviceID   string `json:"device_id"`
	Name       string `json:"name"`
	Type       string `json:"type"`
	OSVersion  string `json:"os_version"`
	AppVersion string `json:"app_version"`
	PublicKey  string `json:"public_key"`
}

type Tokens struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"`
	DeviceID     string `json:"device_id"`
	UserID       uint64 `json:"user_id"`
}

type Principal struct {
	UserID    uint64
	DeviceID  string
	SessionID string
}

var validTypes = map[string]bool{"windows": true, "macos": true, "linux": true, "android": true, "ios": true}

func (s *Service) Register(ctx context.Context, username, password string) (uint64, error) {
	username = strings.TrimSpace(username)
	if l := len([]rune(username)); l < 3 || l > 32 {
		return 0, apiutil.Err(400, "invalid_username", "username must be 3-32 characters")
	}
	if len(password) < 8 || len(password) > 128 {
		return 0, apiutil.Err(400, "invalid_password", "password must be 8-128 characters")
	}
	res, err := s.DB.ExecContext(ctx, `INSERT INTO users(username,password_hash) VALUES(?,?)`, username, hashPassword(password))
	if err != nil {
		var me *mysql.MySQLError
		if errors.As(err, &me) && me.Number == 1062 {
			return 0, apiutil.Err(409, "username_taken", "username already exists")
		}
		return 0, err
	}
	id, _ := res.LastInsertId()
	return uint64(id), nil
}

// Login verifies credentials and registers the device (or re-authenticates a known one).
func (s *Service) Login(ctx context.Context, username, password, ip string, d DeviceInfo) (*Tokens, error) {
	key := strings.ToLower(username) + "|" + ip
	if s.tooManyFailures(key) {
		return nil, apiutil.Err(429, "too_many_attempts", "too many failed logins, retry later")
	}
	var uid uint64
	var hash string
	err := s.DB.QueryRowContext(ctx, `SELECT id,password_hash FROM users WHERE username=?`, strings.TrimSpace(username)).Scan(&uid, &hash)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	// Verify against a dummy hash when the user is unknown to keep timing similar.
	if errors.Is(err, sql.ErrNoRows) {
		hash = dummyHash
	}
	if !verifyPassword(password, hash) || errors.Is(err, sql.ErrNoRows) {
		s.recordFailure(key)
		return nil, apiutil.Err(401, "invalid_credentials", "wrong username or password")
	}
	deviceID, err := s.ensureDevice(ctx, uid, d)
	if err != nil {
		return nil, err
	}
	return s.newSession(ctx, uid, deviceID)
}

func (s *Service) ensureDevice(ctx context.Context, uid uint64, d DeviceInfo) (string, error) {
	if d.DeviceID != "" {
		var owner uint64
		var revoked sql.NullTime
		err := s.DB.QueryRowContext(ctx, `SELECT user_id,revoked_at FROM devices WHERE id=?`, d.DeviceID).Scan(&owner, &revoked)
		if err == nil && owner == uid && !revoked.Valid {
			return d.DeviceID, nil
		}
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return "", err
		}
		// Unknown / revoked / foreign device id: credentials lost, fall through to re-register.
	}
	d.Type = strings.ToLower(d.Type)
	if !validTypes[d.Type] {
		return "", apiutil.Err(400, "invalid_device_type", "device type must be windows|macos|linux|android|ios")
	}
	if d.PublicKey == "" || len(d.PublicKey) > 128 {
		return "", apiutil.Err(400, "invalid_public_key", "public_key required")
	}
	name := strings.TrimSpace(d.Name)
	if name == "" || len([]rune(name)) > 64 {
		return "", apiutil.Err(400, "invalid_device_name", "device name must be 1-64 characters")
	}
	id := uuid.NewString()
	_, err := s.DB.ExecContext(ctx, `INSERT INTO devices(id,user_id,name,device_type,os_version,app_version,public_key) VALUES(?,?,?,?,?,?,?)`,
		id, uid, name, d.Type, d.OSVersion, d.AppVersion, d.PublicKey)
	return id, err
}

func (s *Service) newSession(ctx context.Context, uid uint64, deviceID string) (*Tokens, error) {
	sid := uuid.NewString()
	refresh := randomToken()
	_, err := s.DB.ExecContext(ctx, `INSERT INTO device_sessions(id,device_id,refresh_token_hash,expires_at) VALUES(?,?,?,?)`,
		sid, deviceID, sha(refresh), time.Now().UTC().Add(s.RefreshTTL))
	if err != nil {
		return nil, err
	}
	return s.tokens(uid, deviceID, sid, refresh)
}

func (s *Service) tokens(uid uint64, deviceID, sid, refresh string) (*Tokens, error) {
	claims := jwt.MapClaims{"sub": fmt.Sprint(uid), "did": deviceID, "sid": sid, "exp": time.Now().Add(s.AccessTTL).Unix()}
	at, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(s.Secret)
	if err != nil {
		return nil, err
	}
	return &Tokens{AccessToken: at, RefreshToken: refresh, ExpiresIn: int(s.AccessTTL.Seconds()), DeviceID: deviceID, UserID: uid}, nil
}

// Refresh rotates the refresh token. Reuse of a rotated token revokes the session.
func (s *Service) Refresh(ctx context.Context, refresh string) (*Tokens, error) {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	var sid, did string
	var uid uint64
	var exp time.Time
	var revoked sql.NullTime
	var devRevoked sql.NullTime
	err = tx.QueryRowContext(ctx, `SELECT s.id,s.device_id,d.user_id,s.expires_at,s.revoked_at,d.revoked_at
		FROM device_sessions s JOIN devices d ON d.id=s.device_id WHERE s.refresh_token_hash=? FOR UPDATE`, sha(refresh)).
		Scan(&sid, &did, &uid, &exp, &revoked, &devRevoked)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, apiutil.ErrUnauthorized
	}
	if err != nil {
		return nil, err
	}
	if revoked.Valid {
		// Possible token theft: kill every session of this device.
		_, _ = tx.ExecContext(ctx, `UPDATE device_sessions SET revoked_at=UTC_TIMESTAMP(3) WHERE device_id=? AND revoked_at IS NULL`, did)
		_ = tx.Commit()
		return nil, apiutil.ErrUnauthorized
	}
	if devRevoked.Valid || time.Now().UTC().After(exp) {
		return nil, apiutil.ErrUnauthorized
	}
	newRefresh := randomToken()
	if _, err := tx.ExecContext(ctx, `UPDATE device_sessions SET refresh_token_hash=? WHERE id=?`, sha(newRefresh), sid); err != nil {
		return nil, err
	}
	// Keep the old hash recognisable as "used" by recording it in a revoked tombstone row.
	if _, err := tx.ExecContext(ctx, `INSERT INTO device_sessions(id,device_id,refresh_token_hash,expires_at,revoked_at) VALUES(?,?,?,?,UTC_TIMESTAMP(3))`,
		uuid.NewString(), did, sha(refresh), exp); err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return s.tokens(uid, did, sid, newRefresh)
}

// ChangePassword verifies the old password, stores the new hash and signs out every other device
// of the account (PRD AUTH-008); the calling device keeps its session.
func (s *Service) ChangePassword(ctx context.Context, p Principal, oldPw, newPw string) error {
	key := fmt.Sprintf("pw|%d", p.UserID)
	if s.tooManyFailures(key) {
		return apiutil.Err(429, "too_many_attempts", "too many failed attempts, retry later")
	}
	if len(newPw) < 8 || len(newPw) > 128 {
		return apiutil.Err(400, "invalid_password", "password must be 8-128 characters")
	}
	var hash string
	if err := s.DB.QueryRowContext(ctx, `SELECT password_hash FROM users WHERE id=?`, p.UserID).Scan(&hash); err != nil {
		return err
	}
	if !verifyPassword(oldPw, hash) {
		s.recordFailure(key)
		return apiutil.Err(401, "invalid_credentials", "current password is wrong")
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `UPDATE users SET password_hash=? WHERE id=?`, hashPassword(newPw), p.UserID); err != nil {
		return err
	}
	rows, err := tx.QueryContext(ctx, `SELECT DISTINCT d.id FROM devices d JOIN device_sessions s ON s.device_id=d.id
		WHERE d.user_id=? AND d.id<>? AND s.revoked_at IS NULL`, p.UserID, p.DeviceID)
	if err != nil {
		return err
	}
	var others []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			others = append(others, id)
		}
	}
	rows.Close()
	if _, err := tx.ExecContext(ctx, `UPDATE device_sessions s JOIN devices d ON d.id=s.device_id
		SET s.revoked_at=UTC_TIMESTAMP(3) WHERE d.user_id=? AND d.id<>? AND s.revoked_at IS NULL`, p.UserID, p.DeviceID); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	if s.OnRevoke != nil && len(others) > 0 {
		s.OnRevoke(others)
	}
	return nil
}

func (s *Service) Logout(ctx context.Context, p Principal) error {
	_, err := s.DB.ExecContext(ctx, `UPDATE device_sessions SET revoked_at=UTC_TIMESTAMP(3) WHERE id=? AND revoked_at IS NULL`, p.SessionID)
	return err
}

// Authenticate validates an access token and that its session and device are still live.
func (s *Service) Authenticate(ctx context.Context, token string) (*Principal, error) {
	var claims jwt.MapClaims
	t, err := jwt.ParseWithClaims(token, &claims, func(*jwt.Token) (any, error) { return s.Secret, nil }, jwt.WithValidMethods([]string{"HS256"}))
	if err != nil || !t.Valid {
		return nil, apiutil.ErrUnauthorized
	}
	var uid uint64
	fmt.Sscan(fmt.Sprint(claims["sub"]), &uid)
	did, _ := claims["did"].(string)
	sid, _ := claims["sid"].(string)
	var ok int
	err = s.DB.QueryRowContext(ctx, `SELECT 1 FROM device_sessions s JOIN devices d ON d.id=s.device_id
		WHERE s.id=? AND s.revoked_at IS NULL AND d.id=? AND d.user_id=? AND d.revoked_at IS NULL`, sid, did, uid).Scan(&ok)
	if err != nil {
		return nil, apiutil.ErrUnauthorized
	}
	return &Principal{UserID: uid, DeviceID: did, SessionID: sid}, nil
}

func (s *Service) tooManyFailures(key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.recent(key)) >= 5
}

func (s *Service) recordFailure(key string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.failures[key] = append(s.recent(key), time.Now())
}

func (s *Service) recent(key string) []time.Time {
	cut := time.Now().Add(-5 * time.Minute)
	var out []time.Time
	for _, t := range s.failures[key] {
		if t.After(cut) {
			out = append(out, t)
		}
	}
	s.failures[key] = out
	return out
}

func randomToken() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

func sha(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }

// Argon2id, PHC-like encoding: $argon2id$m=65536,t=2,p=1$salt$hash
func hashPassword(pw string) string {
	salt := make([]byte, 16)
	_, _ = rand.Read(salt)
	h := argon2.IDKey([]byte(pw), salt, 2, 64*1024, 1, 32)
	return fmt.Sprintf("$argon2id$m=65536,t=2,p=1$%s$%s", base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(h))
}

func verifyPassword(pw, enc string) bool {
	p := strings.Split(enc, "$")
	if len(p) != 5 || p[1] != "argon2id" {
		return false
	}
	salt, e1 := base64.RawStdEncoding.DecodeString(p[3])
	want, e2 := base64.RawStdEncoding.DecodeString(p[4])
	if e1 != nil || e2 != nil {
		return false
	}
	got := argon2.IDKey([]byte(pw), salt, 2, 64*1024, 1, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1
}

var dummyHash = hashPassword("linkory-dummy-password")
