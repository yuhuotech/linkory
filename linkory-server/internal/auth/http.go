package auth

import (
	"context"
	"net"
	"net/http"
	"strings"

	"github.com/linkory/linkory-server/internal/apiutil"
)

type ctxKey struct{}

func PrincipalFrom(ctx context.Context) *Principal {
	p, _ := ctx.Value(ctxKey{}).(*Principal)
	return p
}

// Middleware requires a valid Bearer access token.
func (s *Service) Middleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok {
			apiutil.Fail(w, apiutil.ErrUnauthorized)
			return
		}
		p, err := s.Authenticate(r.Context(), tok)
		if err != nil {
			apiutil.Fail(w, err)
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, p)))
	}
}

func (s *Service) Routes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/auth/register", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Username, Password string }
		if err := apiutil.Decode(r, &req); err != nil {
			apiutil.Fail(w, err)
			return
		}
		id, err := s.Register(r.Context(), req.Username, req.Password)
		if err != nil {
			apiutil.Fail(w, err)
			return
		}
		apiutil.JSON(w, 201, map[string]any{"user_id": id})
	})
	mux.HandleFunc("POST /api/v1/auth/login", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Username string     `json:"username"`
			Password string     `json:"password"`
			Device   DeviceInfo `json:"device"`
		}
		if err := apiutil.Decode(r, &req); err != nil {
			apiutil.Fail(w, err)
			return
		}
		ip, _, _ := net.SplitHostPort(r.RemoteAddr)
		t, err := s.Login(r.Context(), req.Username, req.Password, ip, req.Device)
		if err != nil {
			apiutil.Fail(w, err)
			return
		}
		apiutil.JSON(w, 200, t)
	})
	mux.HandleFunc("POST /api/v1/auth/refresh", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			RefreshToken string `json:"refresh_token"`
		}
		if err := apiutil.Decode(r, &req); err != nil {
			apiutil.Fail(w, err)
			return
		}
		t, err := s.Refresh(r.Context(), req.RefreshToken)
		if err != nil {
			apiutil.Fail(w, err)
			return
		}
		apiutil.JSON(w, 200, t)
	})
	mux.HandleFunc("POST /api/v1/auth/password", s.Middleware(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Old string `json:"old_password"`
			New string `json:"new_password"`
		}
		if err := apiutil.Decode(r, &req); err != nil {
			apiutil.Fail(w, err)
			return
		}
		if err := s.ChangePassword(r.Context(), *PrincipalFrom(r.Context()), req.Old, req.New); err != nil {
			apiutil.Fail(w, err)
			return
		}
		w.WriteHeader(204)
	}))
	mux.HandleFunc("POST /api/v1/auth/logout", s.Middleware(func(w http.ResponseWriter, r *http.Request) {
		if err := s.Logout(r.Context(), *PrincipalFrom(r.Context())); err != nil {
			apiutil.Fail(w, err)
			return
		}
		w.WriteHeader(204)
	}))
}
