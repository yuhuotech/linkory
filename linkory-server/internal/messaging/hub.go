package messaging

import (
	"context"
	"database/sql"
	"encoding/json"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Envelope is the wire format for every WebSocket frame (protocol v1).
type Envelope struct {
	V         int             `json:"v"`
	Type      string          `json:"type"`
	EventID   string          `json:"event_id,omitempty"`
	RequestID string          `json:"request_id,omitempty"`
	TS        int64           `json:"ts"`
	Data      json.RawMessage `json:"data,omitempty"`
}

type client struct {
	deviceID string
	userID   uint64
	out      chan []byte
	conn     *websocket.Conn
	cancel   context.CancelFunc
	lanAddrs []string // where this device accepts direct transfers (guarded by Hub.mu)
	lanPort  int
}

// Hub tracks live device connections (single-instance, in-memory presence).
type Hub struct {
	DB    *sql.DB
	Store *Store

	mu      sync.RWMutex
	clients map[string]*client
}

func NewHub(db *sql.DB, store *Store) *Hub {
	h := &Hub{DB: db, Store: store, clients: map[string]*client{}}
	_, _ = db.Exec(`UPDATE devices SET status='offline' WHERE status='online'`)
	return h
}

func (h *Hub) Online(deviceID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	_, ok := h.clients[deviceID]
	return ok
}

// SetLAN stores a device's direct-transfer endpoint for as long as it stays connected.
func (h *Hub) SetLAN(deviceID string, addrs []string, port int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if c := h.clients[deviceID]; c != nil {
		c.lanAddrs, c.lanPort = addrs, port
	}
}

// LAN returns the device's reported direct-transfer endpoint, if any.
func (h *Hub) LAN(deviceID string) ([]string, int) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	if c := h.clients[deviceID]; c != nil {
		return c.lanAddrs, c.lanPort
	}
	return nil, 0
}

// Send queues a frame for a device; false when it is offline or its buffer is full.
func (h *Hub) Send(deviceID string, typ string, data any) bool {
	h.mu.RLock()
	c := h.clients[deviceID]
	h.mu.RUnlock()
	return c != nil && c.send(typ, data)
}

func (c *client) send(typ string, data any) bool {
	raw, _ := json.Marshal(data)
	b, _ := json.Marshal(Envelope{V: 1, Type: typ, EventID: newID(), TS: time.Now().UnixMilli(), Data: raw})
	select {
	case c.out <- b:
		return true
	default:
		return false
	}
}

// Disconnect drops a device's live connection (e.g. after it was removed).
func (h *Hub) Disconnect(deviceID string) {
	h.mu.RLock()
	c := h.clients[deviceID]
	h.mu.RUnlock()
	if c != nil {
		c.cancel()
	}
}

func (h *Hub) register(c *client) {
	h.mu.Lock()
	old := h.clients[c.deviceID]
	h.clients[c.deviceID] = c
	h.mu.Unlock()
	if old != nil {
		old.cancel() // a device has one live connection; newest wins
	}
	h.setStatus(c.deviceID, "online")
	h.broadcastPresence(c.userID, c.deviceID, "device.online")
}

func (h *Hub) unregister(c *client) {
	h.mu.Lock()
	replaced := h.clients[c.deviceID] != c
	if !replaced {
		delete(h.clients, c.deviceID)
	}
	h.mu.Unlock()
	if replaced {
		return
	}
	h.setStatus(c.deviceID, "offline")
	h.broadcastPresence(c.userID, c.deviceID, "device.offline")
}

func (h *Hub) setStatus(deviceID, status string) {
	_, _ = h.DB.Exec(`UPDATE devices SET status=?, last_seen_at=UTC_TIMESTAMP(3) WHERE id=? AND revoked_at IS NULL`, status, deviceID)
}

func (h *Hub) broadcastPresence(userID uint64, deviceID, typ string) {
	rows, err := h.DB.Query(`SELECT id FROM devices WHERE user_id=? AND revoked_at IS NULL AND id<>?`, userID, deviceID)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			h.Send(id, typ, map[string]string{"device_id": deviceID})
		}
	}
}

// OnlineCount is the number of devices with a live connection.
func (h *Hub) OnlineCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.clients)
}

// OnlineDevices lists the account's devices that currently have a live connection.
func (h *Hub) OnlineDevices(userID uint64, except string) []string {
	h.mu.RLock()
	defer h.mu.RUnlock()
	var out []string
	for id, c := range h.clients {
		if c.userID == userID && id != except {
			out = append(out, id)
		}
	}
	return out
}
