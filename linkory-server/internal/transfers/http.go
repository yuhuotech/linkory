package transfers

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"hash"
	"io"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/linkory/linkory-server/internal/apiutil"
	"github.com/linkory/linkory-server/internal/auth"
)

// Notifier pushes WS events to devices (implemented by messaging.Hub).
type Notifier interface {
	Send(deviceID, typ string, data any) bool
	Online(deviceID string) bool
	LAN(deviceID string) ([]string, int)
}

type Handler struct {
	Svc  *Service
	Auth *auth.Service
	Hub  Notifier

	mu     sync.Mutex
	relays map[string]*relay
}

// relay is the in-memory rendezvous between the sender's upload and the receiver's download.
// File bytes flow through an io.Pipe and are never written to disk.
type relay struct {
	pr              *io.PipeReader
	pw              *io.PipeWriter
	senderIn        chan struct{}
	receiverIn      chan struct{}
	done            int
	senderClaimed   bool
	receiverClaimed bool
}

var errCancelled = errors.New("transfer cancelled")

const peerWait = 60 * time.Second

func (h *Handler) Routes(mux *http.ServeMux) {
	h.relays = map[string]*relay{}
	m := h.Auth.Middleware
	mux.HandleFunc("POST /api/v1/transfers", m(h.create))
	mux.HandleFunc("GET /api/v1/transfers", m(h.list))
	mux.HandleFunc("GET /api/v1/transfers/{id}", m(h.get))
	mux.HandleFunc("POST /api/v1/transfers/{id}/accept", m(h.accept))
	mux.HandleFunc("POST /api/v1/transfers/{id}/reject", m(h.reject))
	mux.HandleFunc("POST /api/v1/transfers/{id}/cancel", m(h.cancel))
	mux.HandleFunc("POST /api/v1/transfers/{id}/complete", m(h.complete))
	mux.HandleFunc("POST /api/v1/transfers/{id}/fail", m(h.fail))
	mux.HandleFunc("POST /api/v1/transfers/{id}/lan/start", m(h.lanStart))
	mux.HandleFunc("PUT /api/v1/transfers/{id}/data", m(h.upload))
	mux.HandleFunc("GET /api/v1/transfers/{id}/data", m(h.download))
}

// RunSweeper periodically expires stale tasks and tells both ends.
func (h *Handler) RunSweeper(ctx context.Context) {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			for _, task := range h.Svc.Sweep(ctx) {
				h.abort(task.ID)
				h.notifyBoth(task, "transfer."+lower(task.Status))
			}
		}
	}
}

func lower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}

// decorate attaches the receiver's current direct-transfer endpoint while a direct attempt is useful.
func (h *Handler) decorate(t *Task) *Task {
	if t.Status == WaitingAccept || t.Status == Accepted {
		if addrs, port := h.Hub.LAN(t.Receiver); port > 0 && len(addrs) > 0 {
			t.ReceiverLAN = &LANInfo{Addrs: addrs, Port: port}
		}
	}
	return t
}

func (h *Handler) notifyBoth(t *Task, typ string) {
	h.decorate(t)
	h.Hub.Send(t.Sender, typ, t)
	h.Hub.Send(t.Receiver, typ, t)
}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	p := auth.PrincipalFrom(r.Context())
	var req struct {
		To       string `json:"to_device_id"`
		FileName string `json:"file_name"`
		Size     uint64 `json:"size"`
		SHA256   string `json:"sha256"`
	}
	if err := apiutil.Decode(r, &req); err != nil {
		apiutil.Fail(w, err)
		return
	}
	t, err := h.Svc.Create(r.Context(), p.UserID, p.DeviceID, req.To, req.FileName, req.Size, req.SHA256, h.Hub.Online(req.To))
	if err != nil {
		apiutil.Fail(w, err)
		return
	}
	if !h.Hub.Send(t.Receiver, "transfer.offer", t) {
		h.Svc.Transition(r.Context(), t.ID, Failed, "receiver unreachable", WaitingAccept)
		apiutil.Fail(w, apiutil.Err(409, "receiver_offline", "target device is offline"))
		return
	}
	apiutil.JSON(w, 201, h.decorate(t))
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	ts, err := h.Svc.List(r.Context(), auth.PrincipalFrom(r.Context()).DeviceID, limit)
	if err != nil {
		apiutil.Fail(w, err)
		return
	}
	apiutil.JSON(w, 200, map[string]any{"transfers": ts})
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
	t, err := h.Svc.Get(r.Context(), r.PathValue("id"), auth.PrincipalFrom(r.Context()).DeviceID)
	if err != nil {
		apiutil.Fail(w, err)
		return
	}
	apiutil.JSON(w, 200, h.decorate(t))
}

// act loads the task, checks the caller's role, performs the guarded transition and notifies.
func (h *Handler) act(w http.ResponseWriter, r *http.Request, role, to, event, errMsg string, from ...string) {
	h.actMode(w, r, role, to, event, errMsg, "", from...)
}

// actMode is act plus an optional transfer mode recorded atomically with a successful transition.
func (h *Handler) actMode(w http.ResponseWriter, r *http.Request, role, to, event, errMsg, mode string, from ...string) {
	p := auth.PrincipalFrom(r.Context())
	t, err := h.Svc.Get(r.Context(), r.PathValue("id"), p.DeviceID)
	if err != nil {
		apiutil.Fail(w, err)
		return
	}
	if (role == "receiver" && p.DeviceID != t.Receiver) || (role == "sender" && p.DeviceID != t.Sender) {
		apiutil.Fail(w, apiutil.ErrForbidden)
		return
	}
	ok, err := h.Svc.Transition(r.Context(), t.ID, to, errMsg, from...)
	if err != nil {
		apiutil.Fail(w, err)
		return
	}
	if !ok {
		cur, _ := h.Svc.Get(r.Context(), t.ID, p.DeviceID)
		apiutil.Fail(w, apiutil.Err(409, "invalid_state", "task is "+cur.Status+", transition not allowed"))
		return
	}
	if mode != "" {
		h.Svc.SetMode(r.Context(), t.ID, mode)
	}
	t, _ = h.Svc.Get(r.Context(), t.ID, p.DeviceID)
	if to == Cancelled || to == Failed {
		h.abort(t.ID)
	}
	h.notifyBoth(t, event)
	apiutil.JSON(w, 200, h.decorate(t))
}

func (h *Handler) accept(w http.ResponseWriter, r *http.Request) {
	h.act(w, r, "receiver", Accepted, "transfer.accept", "", WaitingAccept)
}
func (h *Handler) reject(w http.ResponseWriter, r *http.Request) {
	h.act(w, r, "receiver", Rejected, "transfer.reject", "", WaitingAccept)
}
func (h *Handler) cancel(w http.ResponseWriter, r *http.Request) {
	h.act(w, r, "any", Cancelled, "transfer.cancel", "", WaitingAccept, Accepted, Transferring, Verifying)
}

// complete: the receiver confirms its own SHA-256 check passed and the file was saved.
// Body {"via":"lan"} reports a direct transfer that never touched the relay: the receiver verified
// the declared SHA-256 itself, so completion is allowed straight from ACCEPTED/TRANSFERRING.
func (h *Handler) complete(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Via string `json:"via"`
	}
	_ = apiutil.Decode(r, &req)
	if req.Via == "lan" {
		h.actMode(w, r, "receiver", Completed, "transfer.complete", "", "lan", Accepted, Transferring)
		h.abort(r.PathValue("id"))
		return
	}
	h.act(w, r, "receiver", Completed, "transfer.complete", "", Verifying)
}

// lanStart: the receiver authenticated a direct connection from the sender. The task moves to
// TRANSFERRING (so it is not expired while bytes flow peer-to-peer) with mode=lan. If the direct
// path later breaks, the sender falls back to the relay, which also accepts TRANSFERRING tasks.
func (h *Handler) lanStart(w http.ResponseWriter, r *http.Request) {
	h.actMode(w, r, "receiver", Transferring, "transfer.start", "", "lan", Accepted)
}

// fail: the receiver reports a local failure (checksum mismatch, disk full, ...).
func (h *Handler) fail(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Reason string `json:"reason"`
	}
	_ = apiutil.Decode(r, &req)
	if len(req.Reason) > 200 {
		req.Reason = req.Reason[:200]
	}
	h.act(w, r, "receiver", Failed, "transfer.fail", "receiver: "+req.Reason, Accepted, Transferring, Verifying)
}

func (h *Handler) abort(id string) {
	h.mu.Lock()
	rl := h.relays[id]
	delete(h.relays, id)
	h.mu.Unlock()
	if rl != nil {
		rl.pr.CloseWithError(errCancelled)
		rl.pw.CloseWithError(errCancelled)
	}
}

func (h *Handler) relayFor(id string) *relay {
	h.mu.Lock()
	defer h.mu.Unlock()
	rl := h.relays[id]
	if rl == nil {
		pr, pw := io.Pipe()
		rl = &relay{pr: pr, pw: pw, senderIn: make(chan struct{}), receiverIn: make(chan struct{})}
		h.relays[id] = rl
	}
	return rl
}

// claim marks a side as attached; false if that side was already attached (no resume in V1.0).
func (h *Handler) claim(rl *relay, sender bool) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if sender {
		if rl.senderClaimed {
			return false
		}
		rl.senderClaimed = true
		close(rl.senderIn)
		return true
	}
	if rl.receiverClaimed {
		return false
	}
	rl.receiverClaimed = true
	close(rl.receiverIn)
	return true
}

type countWriter struct {
	w        io.Writer
	h        hash.Hash
	n        uint64
	last     time.Time
	progress func(n uint64)
}

func (c *countWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.h.Write(p[:n])
	c.n += uint64(n)
	if time.Since(c.last) > 500*time.Millisecond {
		c.last = time.Now()
		c.progress(c.n)
	}
	return n, err
}

func (h *Handler) task(w http.ResponseWriter, r *http.Request, wantSender bool) (*Task, bool) {
	p := auth.PrincipalFrom(r.Context())
	t, err := h.Svc.Get(r.Context(), r.PathValue("id"), p.DeviceID)
	if err != nil {
		apiutil.Fail(w, err)
		return nil, false
	}
	if (wantSender && p.DeviceID != t.Sender) || (!wantSender && p.DeviceID != t.Receiver) {
		apiutil.Fail(w, apiutil.ErrForbidden)
		return nil, false
	}
	if t.Status != Accepted && t.Status != Transferring {
		apiutil.Fail(w, apiutil.Err(409, "invalid_state", "task is "+t.Status))
		return nil, false
	}
	return t, true
}

// upload streams the sender's body into the pipe once the receiver is attached.
func (h *Handler) upload(w http.ResponseWriter, r *http.Request) {
	t, ok := h.task(w, r, true)
	if !ok {
		return
	}
	rl := h.relayFor(t.ID)
	if !h.claim(rl, true) {
		apiutil.Fail(w, apiutil.Err(409, "already_attached", "sender already attached"))
		return
	}
	defer h.finish(t.ID, rl)
	select {
	case <-rl.receiverIn:
	case <-time.After(peerWait):
		h.release(t.ID, rl)
		apiutil.Fail(w, apiutil.Err(408, "peer_timeout", "receiver did not start downloading; retry"))
		return
	case <-r.Context().Done():
		h.release(t.ID, rl)
		return
	}
	if ok, _ := h.Svc.Transition(r.Context(), t.ID, Transferring, "", Accepted); ok {
		cur, _ := h.Svc.Get(r.Context(), t.ID, t.Sender)
		h.notifyBoth(cur, "transfer.start")
	} else if t.Mode != "relay" {
		h.Svc.SetMode(r.Context(), t.ID, "relay") // direct path was abandoned; the relay carries the file
	}

	hasher := sha256.New()
	cw := &countWriter{w: rl.pw, h: hasher, last: time.Now(), progress: func(n uint64) {
		ev := map[string]any{"id": t.ID, "bytes": n, "size": t.Size}
		h.Hub.Send(t.Sender, "transfer.progress", ev)
		h.Hub.Send(t.Receiver, "transfer.progress", ev)
	}}
	body := http.MaxBytesReader(w, r.Body, int64(t.Size)+1)
	_, copyErr := io.Copy(cw, body)
	ctx := context.WithoutCancel(r.Context())

	fail := func(msg string) {
		if ok, _ := h.Svc.Transition(ctx, t.ID, Failed, msg, Accepted, Transferring); ok {
			cur, _ := h.Svc.Get(ctx, t.ID, t.Sender)
			h.notifyBoth(cur, "transfer.fail")
		}
		rl.pw.CloseWithError(errors.New(msg))
		apiutil.Fail(w, apiutil.Err(502, "transfer_failed", msg))
	}
	switch {
	case copyErr != nil:
		fail("upload interrupted")
	case cw.n != t.Size:
		fail("size mismatch")
	case hex.EncodeToString(hasher.Sum(nil)) != t.SHA256:
		fail("checksum mismatch")
	default:
		// Move to VERIFYING before releasing EOF to the receiver, so its /complete cannot race ahead.
		if ok, _ := h.Svc.Transition(ctx, t.ID, Verifying, "", Transferring); !ok {
			rl.pw.CloseWithError(errCancelled)
			apiutil.Fail(w, apiutil.Err(409, "invalid_state", "transfer was cancelled"))
			return
		}
		rl.pw.Close()
		apiutil.JSON(w, 200, map[string]any{"status": Verifying, "bytes": cw.n})
	}
}

// download streams the pipe to the receiver.
func (h *Handler) download(w http.ResponseWriter, r *http.Request) {
	t, ok := h.task(w, r, false)
	if !ok {
		return
	}
	rl := h.relayFor(t.ID)
	if !h.claim(rl, false) {
		apiutil.Fail(w, apiutil.Err(409, "already_attached", "receiver already attached"))
		return
	}
	defer h.finish(t.ID, rl)
	select {
	case <-rl.senderIn:
	case <-time.After(peerWait):
		h.release(t.ID, rl)
		apiutil.Fail(w, apiutil.Err(408, "peer_timeout", "sender did not start uploading; retry"))
		return
	case <-r.Context().Done():
		h.release(t.ID, rl)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatUint(t.Size, 10))
	w.Header().Set("X-Linkory-SHA256", t.SHA256)
	if _, err := io.Copy(w, rl.pr); err != nil {
		rl.pr.CloseWithError(err) // unblock the sender; its handler marks the task FAILED
	}
}

// release lets a side that timed out waiting for its peer try again.
func (h *Handler) release(id string, rl *relay) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.relays[id] == rl {
		delete(h.relays, id)
	}
}

// finish drops the relay once both sides are done with it.
func (h *Handler) finish(id string, rl *relay) {
	h.mu.Lock()
	defer h.mu.Unlock()
	rl.done++
	if rl.done == 2 && h.relays[id] == rl {
		delete(h.relays, id)
	}
}
