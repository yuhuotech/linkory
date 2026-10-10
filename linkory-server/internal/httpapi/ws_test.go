package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"
)

type wsConn struct {
	t *testing.T
	c *websocket.Conn
}

func dial(t *testing.T, srv *httptest.Server, token string) *wsConn {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(srv.URL, "http")+"/api/v1/ws",
		&websocket.DialOptions{HTTPHeader: http.Header{"Authorization": {"Bearer " + token}}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.CloseNow() })
	return &wsConn{t, c}
}

func (w *wsConn) send(typ string, data any) {
	raw, _ := json.Marshal(data)
	b, _ := json.Marshal(map[string]any{"v": 1, "type": typ, "data": json.RawMessage(raw)})
	if err := w.c.Write(context.Background(), websocket.MessageText, b); err != nil {
		w.t.Fatal(err)
	}
}

// expect reads frames until one of the given type arrives (other frames are skipped).
func (w *wsConn) expect(typ string) map[string]any {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		_, b, err := w.c.Read(ctx)
		if err != nil {
			w.t.Fatalf("waiting for %s: %v", typ, err)
		}
		var env struct {
			Type string
			Data map[string]any
		}
		json.Unmarshal(b, &env)
		if env.Type == typ {
			return env.Data
		}
	}
}

func TestMessaging(t *testing.T) {
	h := setup(t)
	srv := httptest.NewServer(h)
	defer srv.Close()
	for _, u := range []string{"alice", "bob"} {
		call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": u, "password": "password123"})
	}
	a := login(t, h, "alice", "mac")
	b := login(t, h, "alice", "win")
	x := login(t, h, "bob", "bobmac")
	aTok, bTok := a["access_token"].(string), b["access_token"].(string)
	aID, bID := a["device_id"].(string), b["device_id"].(string)

	wa := dial(t, srv, aTok)
	wa.expect("presence.snapshot")
	wb := dial(t, srv, bTok)
	if got := wa.expect("device.online")["device_id"]; got != bID {
		t.Fatalf("presence: %v", got)
	}

	// AT-04 + delivery semantics: ack(server_received) != delivered.
	cid := uuid.NewString()
	msg := map[string]any{"client_msg_id": cid, "to_device_id": bID, "type": "text", "content": "你好"}
	wa.send("message.send", msg)
	ack := wa.expect("message.ack")
	if ack["status"] != "server_received" || ack["client_msg_id"] != cid {
		t.Fatalf("ack: %v", ack)
	}
	rcv := wb.expect("message.receive")
	if rcv["content"] != "你好" || rcv["from_device_id"] != aID {
		t.Fatalf("receive: %v", rcv)
	}
	wb.send("message.delivered", map[string]any{"message_id": rcv["id"]})
	if d := wa.expect("message.delivered"); d["message_id"] != ack["message_id"] {
		t.Fatalf("delivered: %v", d)
	}

	// Idempotent retry: same client_msg_id yields the same message, no second row.
	wa.send("message.send", msg)
	if ack2 := wa.expect("message.ack"); ack2["message_id"] != ack["message_id"] || ack2["duplicate"] != true {
		t.Fatalf("retry ack: %v", ack2)
	}

	// Cross-account target is rejected without revealing it exists.
	wa.send("message.send", map[string]any{"client_msg_id": uuid.NewString(), "to_device_id": x["device_id"], "type": "text", "content": "hi"})
	if e := wa.expect("error"); e["code"] != "not_found" {
		t.Fatalf("cross-account: %v", e)
	}

	// AT-05 offline sync: B disconnects, A sends, B reconnects and gets it once.
	wb.c.Close(websocket.StatusNormalClosure, "")
	if got := wa.expect("device.offline")["device_id"]; got != bID {
		t.Fatalf("offline presence: %v", got)
	}
	wa.send("message.send", map[string]any{"client_msg_id": uuid.NewString(), "to_device_id": bID, "type": "clipboard", "content": "offline-text"})
	wa.expect("message.ack")
	wb2 := dial(t, srv, bTok)
	if m := wb2.expect("message.receive"); m["content"] != "offline-text" || m["type"] != "clipboard" {
		t.Fatalf("offline sync: %v", m)
	}

	// History (both directions) and conversations.
	code, hist := call(h, "GET", "/api/v1/messages?peer_device_id="+bID, aTok, nil)
	if code != 200 || len(hist["messages"].([]any)) != 2 {
		t.Fatalf("history: %d %v", code, hist)
	}
	if code, _ := call(h, "GET", "/api/v1/messages?peer_device_id="+x["device_id"].(string), aTok, nil); code != 404 {
		t.Fatalf("cross-account history: %d", code)
	}
	if _, cv := call(h, "GET", "/api/v1/conversations", aTok, nil); len(cv["conversations"].([]any)) != 1 {
		t.Fatalf("conversations: %v", cv)
	}

	// AT-11: removing a device drops its live connection.
	if code, _ := call(h, "DELETE", "/api/v1/devices/"+bID, aTok, nil); code != 204 {
		t.Fatal("remove", code)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	for {
		if _, _, err := wb2.c.Read(ctx); err != nil {
			if ctx.Err() != nil {
				t.Fatal("removed device still connected")
			}
			break
		}
	}
}

// Browsers cannot set headers on a WebSocket: the token rides in the subprotocol list instead.
func TestWebSocketTokenViaSubprotocol(t *testing.T) {
	h := setup(t)
	srv := httptest.NewServer(h)
	defer srv.Close()
	call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": "dana", "password": "password123"})
	out := login(t, h, "dana", "mac")
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/api/v1/ws"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	c, _, err := websocket.Dial(ctx, url, &websocket.DialOptions{Subprotocols: []string{"linkory.v1", "bearer." + out["access_token"].(string)}})
	if err != nil {
		t.Fatal(err)
	}
	defer c.CloseNow()
	if c.Subprotocol() != "linkory.v1" {
		t.Fatalf("negotiated %q", c.Subprotocol())
	}
	(&wsConn{t, c}).expect("presence.snapshot")

	if _, resp, err := websocket.Dial(ctx, url, &websocket.DialOptions{Subprotocols: []string{"linkory.v1", "bearer.not-a-token"}}); err == nil || resp == nil || resp.StatusCode != 401 {
		t.Fatalf("bad token must be refused with 401: %v", err)
	}
}
