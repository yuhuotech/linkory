package apiutil

import (
	"encoding/json"
	"net/http"
)

type Error struct {
	Status  int    `json:"-"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

func Err(status int, code, msg string) *Error { return &Error{status, code, msg} }

var (
	ErrUnauthorized = Err(401, "unauthorized", "invalid or expired credentials")
	ErrForbidden    = Err(403, "forbidden", "access denied")
	ErrNotFound     = Err(404, "not_found", "resource not found")
)

func JSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func Fail(w http.ResponseWriter, err error) {
	if e, ok := err.(*Error); ok {
		JSON(w, e.Status, e)
		return
	}
	JSON(w, 500, Err(500, "internal", "internal error"))
}

func Decode(r *http.Request, v any) error {
	r.Body = http.MaxBytesReader(nil, r.Body, 1<<20)
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		return Err(400, "bad_request", "invalid JSON body")
	}
	return nil
}
