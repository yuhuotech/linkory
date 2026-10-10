package admin

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/linkory/linkory-server/internal/apiutil"
	"github.com/linkory/linkory-server/internal/audit"
	"github.com/linkory/linkory-server/internal/messaging"
	"golang.org/x/crypto/argon2"
)

const cookieName = "linkory_admin_session"

type Service struct {
	TrustedProxies     []*net.IPNet
	AbortTransfer      func(string)
	DB                 *sql.DB
	Hub                *messaging.Hub
	SecureCookie       bool
	Started            time.Time
	DefaultOfflineDays int
	mu                 sync.Mutex
	failures           map[string][]time.Time
	mon                monitor
}

func NewService(db *sql.DB, hub *messaging.Hub, offlineDays int) *Service {
	_, v4, _ := net.ParseCIDR("127.0.0.1/32")
	_, v6, _ := net.ParseCIDR("::1/128")
	return &Service{TrustedProxies: []*net.IPNet{v4, v6}, DB: db, Hub: hub, SecureCookie: true, Started: time.Now().UTC(), DefaultOfflineDays: offlineDays, failures: map[string][]time.Time{}}
}

type principal struct {
	ID       uint64    `json:"id"`
	Username string    `json:"username"`
	Role     string    `json:"role"`
	CSRF     string    `json:"csrf_token"`
	Expires  time.Time `json:"expires_at"`
	token    string
}
type key struct{}

func actor(r *http.Request) *principal { return r.Context().Value(key{}).(*principal) }
func randomToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}
func digest(s string) string   { b := sha256.Sum256([]byte(s)); return hex.EncodeToString(b[:]) }
func csrf(token string) string { return digest("linkory-admin-csrf\x00" + token) }
func passwordHash(pw string) string {
	salt := make([]byte, 16)
	_, _ = rand.Read(salt)
	hash := argon2.IDKey([]byte(pw), salt, 2, 64*1024, 1, 32)
	return "$argon2id$m=65536,t=2,p=1$" + base64.RawStdEncoding.EncodeToString(salt) + "$" + base64.RawStdEncoding.EncodeToString(hash)
}
func verify(pw, encoded string) bool {
	p := strings.Split(encoded, "$")
	if len(p) != 5 || p[1] != "argon2id" {
		return false
	}
	salt, e := base64.RawStdEncoding.DecodeString(p[3])
	hash, e2 := base64.RawStdEncoding.DecodeString(p[4])
	if e != nil || e2 != nil || len(hash) != 32 || len(salt) != 16 {
		return false
	}
	got := argon2.IDKey([]byte(pw), salt, 2, 64*1024, 1, 32)
	return subtle.ConstantTimeCompare(got, hash) == 1
}

var dummy = passwordHash("not-an-admin-password")

func (s *Service) CreateAccount(ctx context.Context, username, password, role string) error {
	if len([]rune(username)) < 3 || len([]rune(username)) > 64 || utf8.RuneCountInString(password) < 12 || len(password) > 128 || (role != "admin" && role != "readonly") {
		return fmt.Errorf("管理员名称 3–64 字符，密码至少 12 字符且最多 128 字节，角色 admin 或 readonly")
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `INSERT INTO admin_accounts(username,password_hash,role) VALUES(?,?,?)`, username, passwordHash(password), role); err != nil {
		return err
	}
	if err = audit.Write(ctx, tx, audit.Event{Actor: "server-cli", Action: "admin.create", Target: username, Reason: "服务器交互创建", Result: "success"}); err != nil {
		return err
	}
	return tx.Commit()
}
func (s *Service) DisableAccount(ctx context.Context, name string) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx, `UPDATE admin_accounts SET disabled_at=UTC_TIMESTAMP(3) WHERE username=? AND disabled_at IS NULL`, name)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return apiutil.ErrNotFound
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM admin_sessions WHERE admin_id=(SELECT id FROM admin_accounts WHERE username=?)`, name); err != nil {
		return err
	}
	if err = audit.Write(ctx, tx, audit.Event{Actor: "server-cli", Action: "admin.disable", Target: name, Reason: "服务器交互禁用", Result: "success"}); err != nil {
		return err
	}
	return tx.Commit()
}

// ResetPassword is the recovery path for a forgotten password (server CLI only): it also ends every session of the account.
func (s *Service) ResetPassword(ctx context.Context, name, password string) error {
	if utf8.RuneCountInString(password) < 12 || len(password) > 128 {
		return fmt.Errorf("密码至少 12 字符且最多 128 字节")
	}
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var id uint64
	if err = tx.QueryRowContext(ctx, `SELECT id FROM admin_accounts WHERE username=? FOR UPDATE`, name).Scan(&id); err == sql.ErrNoRows {
		return apiutil.ErrNotFound
	} else if err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `UPDATE admin_accounts SET password_hash=? WHERE id=?`, passwordHash(password), id); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM admin_sessions WHERE admin_id=?`, id); err != nil {
		return err
	}
	if err = audit.Write(ctx, tx, audit.Event{Actor: "server-cli", Action: "admin.password_reset", Target: name, Reason: "服务器交互重置密码", Result: "success"}); err != nil {
		return err
	}
	return tx.Commit()
}

type Account struct {
	Username, Role string
	Disabled       bool
	CreatedAt      time.Time
}

func (s *Service) ListAccounts(ctx context.Context) ([]Account, error) {
	rows, err := s.DB.QueryContext(ctx, `SELECT username,role,disabled_at IS NOT NULL,created_at FROM admin_accounts ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Account
	for rows.Next() {
		var a Account
		if err = rows.Scan(&a.Username, &a.Role, &a.Disabled, &a.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// pruneFailures forgets login failures older than the rate-limit window so the map cannot grow without bound.
func (s *Service) pruneFailures() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for k, list := range s.failures {
		keep := false
		for _, t := range list {
			if time.Since(t) < 5*time.Minute {
				keep = true
				break
			}
		}
		if !keep {
			delete(s.failures, k)
		}
	}
}
func (s *Service) SetTrustedProxies(values []string) error {
	out := []*net.IPNet{}
	for _, value := range values {
		_, prefix, e := net.ParseCIDR(strings.TrimSpace(value))
		if e != nil {
			return fmt.Errorf("invalid admin trusted proxy CIDR: %s", value)
		}
		out = append(out, prefix)
	}
	s.TrustedProxies = out
	return nil
}
func (s *Service) trusted(r *http.Request) bool {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	ip := net.ParseIP(host)
	for _, prefix := range s.TrustedProxies {
		if prefix.Contains(ip) {
			return true
		}
	}
	return false
}
func (s *Service) sourceIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	if s.trusted(r) {
		if real := net.ParseIP(r.Header.Get("X-Real-IP")); real != nil {
			return real.String()
		}
	}
	return host
}
func (s *Service) sameOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	u, err := url.Parse(origin)
	if err != nil || origin == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
		return false
	}
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	if s.trusted(r) {
		if v := r.Header.Get("X-Forwarded-Proto"); v == "http" || v == "https" {
			scheme = v
		}
	}
	return u.Host == r.Host && u.Scheme == scheme
}
func (s *Service) event(r *http.Request, action, target, reason, result string) audit.Event {
	p := actor(r)
	return audit.Event{ActorID: p.ID, Actor: p.Username, Action: action, Target: target, Reason: reason, Result: result, IP: s.sourceIP(r)}
}
func (s *Service) protect(write bool, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		cookie, err := r.Cookie(cookieName)
		if err != nil {
			apiutil.Fail(w, apiutil.ErrUnauthorized)
			return
		}
		p := &principal{token: cookie.Value, CSRF: csrf(cookie.Value)}
		err = s.DB.QueryRowContext(r.Context(), `SELECT a.id,a.username,a.role,s.expires_at FROM admin_sessions s JOIN admin_accounts a ON a.id=s.admin_id WHERE s.token_hash=? AND s.expires_at>UTC_TIMESTAMP(3) AND a.disabled_at IS NULL`, digest(cookie.Value)).Scan(&p.ID, &p.Username, &p.Role, &p.Expires)
		if err != nil {
			apiutil.Fail(w, apiutil.ErrUnauthorized)
			return
		}
		r = r.WithContext(context.WithValue(r.Context(), key{}, p))
		unsafe := r.Method != "GET" && r.Method != "HEAD"
		if (r.Header.Get("Origin") != "" && !s.sameOrigin(r)) || (write && p.Role != "admin") || (unsafe && (!s.sameOrigin(r) || subtle.ConstantTimeCompare([]byte(r.Header.Get("X-CSRF-Token")), []byte(p.CSRF)) != 1)) {
			if err := audit.Write(r.Context(), s.DB, s.event(r, "access.denied", r.URL.Path, "", "denied")); err != nil {
				apiutil.Fail(w, err)
				return
			}
			apiutil.Fail(w, apiutil.ErrForbidden)
			return
		}
		next(w, r)
	}
}
func (s *Service) login(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !s.sameOrigin(r) || r.Header.Get("X-Linkory-Admin") != "1" {
		apiutil.Fail(w, apiutil.ErrForbidden)
		return
	}
	var in struct{ Username, Password string }
	if err := apiutil.Decode(r, &in); err != nil {
		apiutil.Fail(w, err)
		return
	}
	in.Username = strings.TrimSpace(in.Username)
	if len([]rune(in.Username)) > 64 || len(in.Password) > 128 {
		apiutil.Fail(w, apiutil.Err(400, "invalid_input", "输入过长"))
		return
	}
	limitKey := s.sourceIP(r)
	s.mu.Lock()
	var recent []time.Time
	for _, t := range s.failures[limitKey] {
		if time.Since(t) < 5*time.Minute {
			recent = append(recent, t)
		}
	}
	s.failures[limitKey] = recent
	blocked := len(recent) >= 5
	s.mu.Unlock()
	if blocked {
		apiutil.Fail(w, apiutil.Err(429, "rate_limited", "失败次数过多，请 5 分钟后重试"))
		return
	}
	var p principal
	var hash string
	err := s.DB.QueryRowContext(r.Context(), `SELECT id,username,role,password_hash FROM admin_accounts WHERE username=? AND disabled_at IS NULL`, in.Username).Scan(&p.ID, &p.Username, &p.Role, &hash)
	if err != nil && err != sql.ErrNoRows {
		apiutil.Fail(w, err)
		return
	}
	if err == sql.ErrNoRows {
		hash = dummy
	}
	if !verify(in.Password, hash) || err == sql.ErrNoRows {
		s.mu.Lock()
		s.failures[limitKey] = append(s.failures[limitKey], time.Now())
		s.mu.Unlock()
		if e := audit.Write(r.Context(), s.DB, audit.Event{Actor: in.Username, Action: "auth.login", Result: "failure", IP: s.sourceIP(r)}); e != nil {
			apiutil.Fail(w, e)
			return
		}
		apiutil.Fail(w, apiutil.Err(401, "invalid_credentials", "账号或密码不正确"))
		return
	}
	token := randomToken()
	p.CSRF = csrf(token)
	p.Expires = time.Now().UTC().Add(8 * time.Hour)
	tx, err := s.DB.BeginTx(r.Context(), nil)
	if err != nil {
		apiutil.Fail(w, err)
		return
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(r.Context(), `INSERT INTO admin_sessions(token_hash,admin_id,expires_at) VALUES(?,?,?)`, digest(token), p.ID, p.Expires); err == nil {
		err = audit.Write(r.Context(), tx, audit.Event{ActorID: p.ID, Actor: p.Username, Action: "auth.login", Result: "success", IP: s.sourceIP(r)})
	}
	if err == nil {
		err = tx.Commit()
	}
	if err != nil {
		apiutil.Fail(w, err)
		return
	}
	s.mu.Lock()
	delete(s.failures, limitKey)
	s.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: token, Path: "/api/admin/", HttpOnly: true, Secure: s.SecureCookie, SameSite: http.SameSiteStrictMode, Expires: p.Expires})
	apiutil.JSON(w, 200, p)
}
func (s *Service) logout(w http.ResponseWriter, r *http.Request) {
	p := actor(r)
	tx, e := s.DB.BeginTx(r.Context(), nil)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	defer tx.Rollback()
	if _, e = tx.ExecContext(r.Context(), `DELETE FROM admin_sessions WHERE token_hash=?`, digest(p.token)); e == nil {
		e = audit.Write(r.Context(), tx, s.event(r, "auth.logout", "", "", "success"))
	}
	if e == nil {
		e = tx.Commit()
	}
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/api/admin/", HttpOnly: true, Secure: s.SecureCookie, SameSite: http.SameSiteStrictMode, MaxAge: -1})
	w.WriteHeader(204)
}
func (s *Service) changePassword(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Old string `json:"old_password"`
		New string `json:"new_password"`
	}
	if e := apiutil.Decode(r, &in); e != nil {
		apiutil.Fail(w, e)
		return
	}
	if utf8.RuneCountInString(in.New) < 12 || len(in.New) > 128 || len(in.Old) > 128 {
		apiutil.Fail(w, apiutil.Err(400, "invalid_password", "新密码至少 12 字符，最多 128 字节"))
		return
	}
	p := actor(r)
	tx, e := s.DB.BeginTx(r.Context(), nil)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	defer tx.Rollback()
	var hash string
	e = tx.QueryRowContext(r.Context(), `SELECT password_hash FROM admin_accounts WHERE id=? FOR UPDATE`, p.ID).Scan(&hash)
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	if !verify(in.Old, hash) {
		apiutil.Fail(w, apiutil.Err(400, "wrong_password", "原密码不正确"))
		return
	}
	if _, e = tx.ExecContext(r.Context(), `UPDATE admin_accounts SET password_hash=? WHERE id=?`, passwordHash(in.New), p.ID); e == nil {
		_, e = tx.ExecContext(r.Context(), `DELETE FROM admin_sessions WHERE admin_id=? AND token_hash<>?`, p.ID, digest(p.token))
	}
	if e == nil {
		e = audit.Write(r.Context(), tx, s.event(r, "auth.password", "self", "本人修改密码", "success"))
	}
	if e == nil {
		e = tx.Commit()
	}
	if e != nil {
		apiutil.Fail(w, e)
		return
	}
	w.WriteHeader(204)
}
