package auth

import (
	"context"
	"crypto/hmac"
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

	// RefreshGrace: presenting a refresh token that was rotated away less than this long ago is
	// treated as a lost response (client retry), not theft: it gets the same successor token back.
	// Beyond it (or after two rotations) reuse revokes every session of the device.
	RefreshGrace time.Duration

	// OnRevoke is called with the devices whose sessions were just revoked (e.g. after a password
	// change) so live connections can be dropped.
	OnRevoke func(deviceIDs []string)

	mu       sync.Mutex
	failures map[string][]time.Time
}

func NewService(db *sql.DB, secret []byte, access, refresh time.Duration) *Service {
	return &Service{DB: db, Secret: secret, AccessTTL: access, RefreshTTL: refresh, RefreshGrace: 20 * time.Second, failures: map[string][]time.Time{}}
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

var validTypes = map[string]bool{"windows": true, "macos": true, "linux": true, "android": true, "ios": true, "web": true}

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
		return "", apiutil.Err(400, "invalid_device_type", "device type must be windows|macos|linux|android|ios|web")
	}
	if d.PublicKey == "" || len(d.PublicKey) > 128 {
		return "", apiutil.Err(400, "invalid_public_key", "public_key required")
	}
	name := strings.TrimSpace(d.Name)
	if name == "" || len([]rune(name)) > 64 {
		return "", apiutil.Err(400, "invalid_device_name", "device name must be 1-64 characters")
	}
	if d.Type == "web" {
		if err := s.makeRoomForWebDevice(ctx, uid); err != nil {
			return "", err
		}
	}
	id := uuid.NewString()
	// Informational fields come from the client (Android reports a long kernel string): clip them
	// to the column sizes instead of failing the login.
	_, err := s.DB.ExecContext(ctx, `INSERT INTO devices(id,user_id,name,device_type,os_version,app_version,public_key) VALUES(?,?,?,?,?,?,?)`,
		id, uid, name, d.Type, clip(d.OSVersion, 64), clip(d.AppVersion, 32), d.PublicKey)
	return id, err
}

// MaxWebDevices caps the browser devices of one account. A browser has no stable hardware identity (clearing
// site data makes a new device), so rather than refusing a sign-in the least recently seen offline one is retired.
const MaxWebDevices = 10

func (s *Service) makeRoomForWebDevice(ctx context.Context, uid uint64) error {
	rows, err := s.DB.QueryContext(ctx, `SELECT id,status FROM devices WHERE user_id=? AND device_type='web' AND revoked_at IS NULL
		ORDER BY COALESCE(last_seen_at,created_at) ASC`, uid)
	if err != nil {
		return err
	}
	type dev struct{ id, status string }
	var all []dev
	for rows.Next() {
		var d dev
		if err := rows.Scan(&d.id, &d.status); err != nil {
			rows.Close()
			return err
		}
		all = append(all, d)
	}
	rows.Close()
	var retire []string
	for _, d := range all {
		if len(all)-len(retire) < MaxWebDevices {
			break
		}
		if d.status != "online" {
			retire = append(retire, d.id)
		}
	}
	if len(all)-len(retire) >= MaxWebDevices {
		return apiutil.Err(409, "too_many_web_devices", "too many browser devices are online; sign out of one first")
	}
	return s.revokeDevices(ctx, retire)
}

// PurgeStaleWebDevices retires browser devices that have not been online for a long time.
func (s *Service) PurgeStaleWebDevices(ctx context.Context, olderThan time.Duration) {
	rows, err := s.DB.QueryContext(ctx, `SELECT id FROM devices WHERE device_type='web' AND revoked_at IS NULL AND status<>'online'
		AND COALESCE(last_seen_at,created_at) < ?`, time.Now().UTC().Add(-olderThan))
	if err != nil {
		return
	}
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	_ = s.revokeDevices(ctx, ids)
}

func (s *Service) revokeDevices(ctx context.Context, ids []string) error {
	for _, id := range ids {
		if _, err := s.DB.ExecContext(ctx, `UPDATE devices SET revoked_at=UTC_TIMESTAMP(3), status='revoked' WHERE id=? AND revoked_at IS NULL`, id); err != nil {
			return err
		}
		if _, err := s.DB.ExecContext(ctx, `UPDATE device_sessions SET revoked_at=UTC_TIMESTAMP(3) WHERE device_id=? AND revoked_at IS NULL`, id); err != nil {
			return err
		}
	}
	if s.OnRevoke != nil && len(ids) > 0 {
		s.OnRevoke(ids)
	}
	return nil
}

// clip truncates to at most n runes.
func clip(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
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
		// A token that was just rotated away and is presented again is almost always a retry after a
		// lost response. The successor is derived from it, so we can hand the same one back.
		if s.RefreshGrace > 0 && time.Since(revoked.Time) < s.RefreshGrace && !devRevoked.Valid {
			next := s.nextRefresh(refresh)
			var cur string
			if tx.QueryRowContext(ctx, `SELECT id FROM device_sessions WHERE device_id=? AND refresh_token_hash=? AND revoked_at IS NULL`, did, sha(next)).Scan(&cur) == nil {
				_ = tx.Commit()
				return s.tokens(uid, did, cur, next)
			}
		}
		// Possible token theft: kill every session of this device.
		_, _ = tx.ExecContext(ctx, `UPDATE device_sessions SET revoked_at=UTC_TIMESTAMP(3) WHERE device_id=? AND revoked_at IS NULL`, did)
		_ = tx.Commit()
		return nil, apiutil.ErrUnauthorized
	}
	if devRevoked.Valid || time.Now().UTC().After(exp) {
		return nil, apiutil.ErrUnauthorized
	}
	newRefresh := s.nextRefresh(refresh)
	// Sliding expiry: an account that keeps using the app stays signed in.
	if _, err := tx.ExecContext(ctx, `UPDATE device_sessions SET refresh_token_hash=?, expires_at=? WHERE id=?`, sha(newRefresh), time.Now().UTC().Add(s.RefreshTTL), sid); err != nil {
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

// PurgeTombstones drops rotated-away refresh rows that are too old to matter for reuse detection.
func (s *Service) PurgeTombstones(ctx context.Context, olderThan time.Duration) {
	_, _ = s.DB.ExecContext(ctx, `DELETE FROM device_sessions WHERE revoked_at IS NOT NULL AND revoked_at < ?`, time.Now().UTC().Add(-olderThan))
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

// nextRefresh derives the successor of a refresh token (keyed with the server secret, so it cannot
// be computed without it) which makes a retried refresh idempotent.
func (s *Service) nextRefresh(prev string) string {
	m := hmac.New(sha256.New, s.Secret)
	m.Write([]byte("linkory-refresh-v1|" + prev))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
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
