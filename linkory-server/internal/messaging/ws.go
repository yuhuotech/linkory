package messaging

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"time"

	"github.com/coder/websocket"

	"github.com/linkory/linkory-server/internal/apiutil"
	"github.com/linkory/linkory-server/internal/auth"
)

const (
	heartbeatTimeout = 90 * time.Second // PRD 4.3: client pings every 30s, server drops after 90s silence
	writeTimeout     = 10 * time.Second
)

type Handler struct {
	Hub        *Hub
	Auth       *auth.Service
	OfflineTTL time.Duration
}

func (h *Handler) Routes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/ws", h.Auth.Middleware(h.serveWS))
	mux.HandleFunc("GET /api/v1/conversations", h.Auth.Middleware(h.conversations))
	mux.HandleFunc("GET /api/v1/messages", h.Auth.Middleware(h.history))
}

func newID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6], b[8] = b[6]&0x0f|0x40, b[8]&0x3f|0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func (h *Handler) serveWS(w http.ResponseWriter, r *http.Request) {
	p := auth.PrincipalFrom(r.Context())
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{Subprotocols: []string{"linkory.v1"}})
	if err != nil {
		return
	}
	conn.SetReadLimit(256 * 1024)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	c := &client{deviceID: p.DeviceID, userID: p.UserID, out: make(chan []byte, 256), conn: conn, cancel: cancel}
	h.Hub.register(c)
	defer func() { h.Hub.unregister(c); conn.CloseNow() }()

	go func() { // writer
		for {
			select {
			case <-ctx.Done():
				conn.Close(websocket.StatusNormalClosure, "bye")
				return
			case b := <-c.out:
				wctx, wcancel := context.WithTimeout(ctx, writeTimeout)
				err := conn.Write(wctx, websocket.MessageText, b)
				wcancel()
				if err != nil {
					cancel()
					return
				}
			}
		}
	}()

	// Initial state: who is online, then everything not yet delivered.
	c.send("presence.snapshot", map[string]any{"online_device_ids": h.Hub.OnlineDevices(p.UserID, p.DeviceID)})
	if pending, err := h.Hub.Store.Pending(ctx, p.DeviceID, h.OfflineTTL); err == nil {
		for _, m := range pending {
			c.send("message.receive", m)
		}
	}

	for {
		rctx, rcancel := context.WithTimeout(ctx, heartbeatTimeout)
		_, data, err := conn.Read(rctx)
		rcancel()
		if err != nil {
			return
		}
		var env Envelope
		if json.Unmarshal(data, &env) != nil {
			c.send("error", map[string]string{"code": "bad_frame", "message": "invalid JSON frame"})
			continue
		}
		h.dispatch(ctx, c, env)
	}
}

func (h *Handler) dispatch(ctx context.Context, c *client, env Envelope) {
	fail := func(err error) {
		code, msg := "internal", "internal error"
		if e, ok := err.(*apiutil.Error); ok {
			code, msg = e.Code, e.Message
		} else {
			slog.Error("ws dispatch", "type", env.Type, "err", err)
		}
		b, _ := json.Marshal(map[string]string{"code": code, "message": msg})
		c.send("error", json.RawMessage(b))
	}
	switch env.Type {
	case "ping":
		c.send("pong", struct{}{})

	case "message.send":
		var req struct {
			ClientMsgID string `json:"client_msg_id"`
			To          string `json:"to_device_id"`
			Type        string `json:"type"`
			Content     string `json:"content"`
		}
		if json.Unmarshal(env.Data, &req) != nil {
			fail(apiutil.Err(400, "bad_request", "invalid message.send data"))
			return
		}
		m, dup, err := h.Hub.Store.Save(ctx, c.userID, c.deviceID, req.To, req.ClientMsgID, req.Type, req.Content)
		if err != nil {
			fail(err)
			return
		}
		// Server received it; this is NOT delivery (PRD 4.4).
		status := "server_received"
		if m.DeliveredAt != nil {
			status = "delivered"
		}
		c.send("message.ack", map[string]any{"client_msg_id": m.ClientMsgID, "message_id": m.ID, "status": status, "created_at": m.CreatedAt, "duplicate": dup})
		if !dup || m.DeliveredAt == nil {
			h.Hub.Send(m.To, "message.receive", m)
		}

	case "message.delivered": // receiver confirms it stored the message
		var req struct {
			MessageID string `json:"message_id"`
		}
		if json.Unmarshal(env.Data, &req) != nil {
			fail(apiutil.Err(400, "bad_request", "invalid message.delivered data"))
			return
		}
		m, err := h.Hub.Store.MarkDelivered(ctx, req.MessageID, c.deviceID)
		if err != nil {
			fail(err)
			return
		}
		if m != nil {
			h.Hub.Send(m.From, "message.delivered", map[string]any{"message_id": m.ID, "client_msg_id": m.ClientMsgID, "delivered_at": m.DeliveredAt})
		}

	case "lan.report": // device tells the server where it listens for same-network direct transfers
		var req struct {
			Addrs []string `json:"addrs"`
			Port  int      `json:"port"`
		}
		if json.Unmarshal(env.Data, &req) != nil || req.Port < 1 || req.Port > 65535 {
			fail(apiutil.Err(400, "bad_request", "invalid lan.report data"))
			return
		}
		h.Hub.SetLAN(c.deviceID, privateAddrs(req.Addrs), req.Port)

	default:
		fail(apiutil.Err(400, "unknown_type", "unknown event type "+env.Type))
	}
}

func (h *Handler) conversations(w http.ResponseWriter, r *http.Request) {
	p := auth.PrincipalFrom(r.Context())
	cs, err := h.Hub.Store.Conversations(r.Context(), p.UserID, p.DeviceID)
	if err != nil {
		apiutil.Fail(w, err)
		return
	}
	apiutil.JSON(w, 200, map[string]any{"conversations": cs})
}

// GET /api/v1/messages?peer_device_id=&before=<unix ms>&limit=
func (h *Handler) history(w http.ResponseWriter, r *http.Request) {
	p := auth.PrincipalFrom(r.Context())
	q := r.URL.Query()
	var before time.Time
	if v := q.Get("before"); v != "" {
		ms, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			apiutil.Fail(w, apiutil.Err(400, "bad_request", "before must be unix milliseconds"))
			return
		}
		before = time.UnixMilli(ms)
	}
	limit, _ := strconv.Atoi(q.Get("limit"))
	ms, err := h.Hub.Store.History(r.Context(), p.UserID, p.DeviceID, q.Get("peer_device_id"), before, limit)
	if err != nil {
		apiutil.Fail(w, err)
		return
	}
	apiutil.JSON(w, 200, map[string]any{"messages": ms})
}

// privateAddrs keeps only loopback / private / link-local literals (max 8): a device must not be
// able to point its peers at arbitrary public hosts.
func privateAddrs(in []string) []string {
	out := []string{}
	for _, a := range in {
		ip := net.ParseIP(a)
		if ip == nil || !(ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()) {
			continue
		}
		out = append(out, ip.String())
		if len(out) == 8 {
			break
		}
	}
	return out
}
