package httpapi

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func hexSum(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

func do(t *testing.T, method, url, token string, body io.Reader) (*http.Response, []byte) {
	req, _ := http.NewRequest(method, url, body)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp, b
}

func TestFileTransfer(t *testing.T) {
	h := setup(t)
	srv := httptest.NewServer(h)
	defer srv.Close()
	for _, u := range []string{"alice", "bob"} {
		call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": u, "password": "password123"})
	}
	a, b, x := login(t, h, "alice", "mac"), login(t, h, "alice", "win"), login(t, h, "bob", "bobmac")
	aTok, bTok, xTok := a["access_token"].(string), b["access_token"].(string), x["access_token"].(string)
	bID := b["device_id"].(string)

	data := make([]byte, 3<<20+17)
	rand.Read(data)
	create := func(name string, payload []byte, sum string) (int, map[string]any) {
		return call(h, "POST", "/api/v1/transfers", aTok, map[string]any{"to_device_id": bID, "file_name": name, "size": len(payload), "sha256": sum})
	}

	// Receiver offline → rejected (PRD 4.8).
	if code, out := create("a.bin", data, hexSum(data)); code != 409 || out["code"] != "receiver_offline" {
		t.Fatalf("offline: %d %v", code, out)
	}

	wb := dial(t, srv, bTok)
	wa := dial(t, srv, aTok)
	wa.expect("presence.snapshot")

	// Validation.
	if code, _ := create("../etc/passwd", data, hexSum(data)); code != 400 {
		t.Fatalf("path traversal name: %d", code)
	}
	if code, _ := create("a.bin", data, "zz"); code != 400 {
		t.Fatalf("bad sha: %d", code)
	}

	// Happy path (AT-07/AT-08).
	code, task := create("a.bin", data, hexSum(data))
	if code != 201 || task["status"] != "WAITING_ACCEPT" {
		t.Fatalf("create: %d %v", code, task)
	}
	id := task["id"].(string)
	base := srv.URL + "/api/v1/transfers/" + id
	if offer := wb.expect("transfer.offer"); offer["id"] != id {
		t.Fatalf("offer: %v", offer)
	}
	// Data cannot flow before the receiver accepts.
	if resp, _ := do(t, "PUT", base+"/data", aTok, bytes.NewReader(data)); resp.StatusCode != 409 {
		t.Fatalf("upload before accept: %d", resp.StatusCode)
	}
	// Sender and strangers cannot accept; only the receiver.
	if resp, _ := do(t, "POST", base+"/accept", aTok, nil); resp.StatusCode != 403 {
		t.Fatalf("sender accept: %d", resp.StatusCode)
	}
	if resp, _ := do(t, "POST", base+"/accept", xTok, nil); resp.StatusCode != 404 {
		t.Fatalf("stranger accept: %d", resp.StatusCode)
	}
	if resp, _ := do(t, "POST", base+"/accept", bTok, nil); resp.StatusCode != 200 {
		t.Fatalf("accept: %d", resp.StatusCode)
	}
	wa.expect("transfer.accept")

	type res struct {
		resp *http.Response
		body []byte
	}
	up, down := make(chan res, 1), make(chan res, 1)
	go func() { r, bd := do(t, "PUT", base+"/data", aTok, bytes.NewReader(data)); up <- res{r, bd} }()
	go func() { r, bd := do(t, "GET", base+"/data", bTok, nil); down <- res{r, bd} }()
	u, d := <-up, <-down
	if u.resp.StatusCode != 200 || d.resp.StatusCode != 200 {
		t.Fatalf("relay: up=%d %s down=%d", u.resp.StatusCode, u.body, d.resp.StatusCode)
	}
	if !bytes.Equal(d.body, data) {
		t.Fatal("received bytes differ")
	}
	if _, cur := call(h, "GET", "/api/v1/transfers/"+id, aTok, nil); cur["status"] != "VERIFYING" {
		t.Fatalf("after relay: %v", cur)
	}
	if resp, _ := do(t, "POST", base+"/complete", bTok, nil); resp.StatusCode != 200 {
		t.Fatalf("complete: %d", resp.StatusCode)
	}
	wa.expect("transfer.complete")
	if resp, _ := do(t, "POST", base+"/cancel", aTok, nil); resp.StatusCode != 409 {
		t.Fatalf("cancel after complete: %d", resp.StatusCode)
	}

	// Checksum mismatch: the task FAILS and the receiver is notified (it also verifies locally).
	bad := append([]byte(nil), data[:1<<20]...)
	_, t2 := create("bad.bin", bad, hexSum(append([]byte("x"), bad[1:]...)))
	base2 := srv.URL + "/api/v1/transfers/" + t2["id"].(string)
	do(t, "POST", base2+"/accept", bTok, nil)
	up, down = make(chan res, 1), make(chan res, 1)
	go func() { r, bd := do(t, "PUT", base2+"/data", aTok, bytes.NewReader(bad)); up <- res{r, bd} }()
	go func() {
		req, _ := http.NewRequest("GET", base2+"/data", nil)
		req.Header.Set("Authorization", "Bearer "+bTok)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			down <- res{nil, nil}
			return
		}
		defer resp.Body.Close()
		bd, _ := io.ReadAll(resp.Body) // bytes may arrive in full; the receiver must verify SHA-256 itself
		down <- res{resp, bd}
	}()
	if u := <-up; u.resp.StatusCode != 502 {
		t.Fatalf("mismatch upload: %d %s", u.resp.StatusCode, u.body)
	}
	<-down
	wb.expect("transfer.fail") // the receiver is told to discard the temp file
	if _, cur := call(h, "GET", "/api/v1/transfers/"+t2["id"].(string), aTok, nil); cur["status"] != "FAILED" {
		t.Fatalf("mismatch status: %v", cur)
	}

	// Reject and cancel paths.
	_, t3 := create("r.bin", bad, hexSum(bad))
	if resp, _ := do(t, "POST", srv.URL+"/api/v1/transfers/"+t3["id"].(string)+"/reject", bTok, nil); resp.StatusCode != 200 {
		t.Fatal("reject", resp.StatusCode)
	}
	wa.expect("transfer.reject")
	_, t4 := create("c.bin", bad, hexSum(bad))
	if resp, _ := do(t, "POST", srv.URL+"/api/v1/transfers/"+t4["id"].(string)+"/cancel", aTok, nil); resp.StatusCode != 200 {
		t.Fatal("cancel", resp.StatusCode)
	}

	// Transfer center.
	if code, list := call(h, "GET", "/api/v1/transfers", aTok, nil); code != 200 || len(list["transfers"].([]any)) != 4 {
		t.Fatalf("list: %d %v", code, list)
	}
	if _, list := call(h, "GET", "/api/v1/transfers", xTok, nil); len(list["transfers"].([]any)) != 0 {
		t.Fatal("stranger sees transfers")
	}
}

// Direct (same-network) transfer negotiation: the server hands both ends a per-task secret and the
// receiver's endpoint, and accepts a receiver-verified completion that never used the relay.
func TestLANNegotiation(t *testing.T) {
	h := setup(t)
	srv := httptest.NewServer(h)
	defer srv.Close()
	call(h, "POST", "/api/v1/auth/register", "", map[string]any{"username": "lanuser", "password": "password123"})
	a, b := login(t, h, "lanuser", "mac"), login(t, h, "lanuser", "win")
	aTok, bTok := a["access_token"].(string), b["access_token"].(string)
	bID := b["device_id"].(string)
	wb, wa := dial(t, srv, bTok), dial(t, srv, aTok)
	wa.expect("presence.snapshot")

	// Only private/loopback literals survive; a public address must be dropped.
	wb.send("lan.report", map[string]any{"addrs": []string{"192.168.1.20", "8.8.8.8", "not-an-ip"}, "port": 40123})
	time.Sleep(200 * time.Millisecond)

	data := []byte("hello direct world")
	code, task := call(h, "POST", "/api/v1/transfers", aTok, map[string]any{"to_device_id": bID, "file_name": "d.txt", "size": len(data), "sha256": hexSum(data)})
	if code != 201 {
		t.Fatalf("create: %d %v", code, task)
	}
	secret, _ := task["lan_secret"].(string)
	if len(secret) != 64 || task["mode"] != "relay" {
		t.Fatalf("secret/mode: %v", task)
	}
	lan, _ := task["receiver_lan"].(map[string]any)
	if lan == nil || lan["port"].(float64) != 40123 || len(lan["addrs"].([]any)) != 1 || lan["addrs"].([]any)[0] != "192.168.1.20" {
		t.Fatalf("receiver_lan: %v", task["receiver_lan"])
	}
	if offer := wb.expect("transfer.offer"); offer["lan_secret"] != secret {
		t.Fatalf("receiver must get the same secret: %v", offer)
	}

	base := srv.URL + "/api/v1/transfers/" + task["id"].(string)
	// Cannot complete before accepting; the sender cannot complete on the receiver's behalf.
	if resp, _ := do(t, "POST", base+"/complete", bTok, bytes.NewReader([]byte(`{"via":"lan"}`))); resp.StatusCode != 409 {
		t.Fatalf("complete before accept: %d", resp.StatusCode)
	}
	do(t, "POST", base+"/accept", bTok, nil)
	if ev := wa.expect("transfer.accept"); ev["receiver_lan"] == nil {
		t.Fatalf("sender must learn the receiver endpoint on accept: %v", ev)
	}
	if resp, _ := do(t, "POST", base+"/complete", aTok, bytes.NewReader([]byte(`{"via":"lan"}`))); resp.StatusCode != 403 {
		t.Fatalf("sender complete: %d", resp.StatusCode)
	}
	if resp, _ := do(t, "POST", base+"/lan/start", aTok, nil); resp.StatusCode != 403 {
		t.Fatalf("sender lan/start: %d", resp.StatusCode)
	}
	if resp, _ := do(t, "POST", base+"/lan/start", bTok, nil); resp.StatusCode != 200 {
		t.Fatalf("lan/start: %d", resp.StatusCode)
	}
	if ev := wa.expect("transfer.start"); ev["mode"] != "lan" || ev["status"] != "TRANSFERRING" {
		t.Fatalf("start event: %v", ev)
	}
	if resp, _ := do(t, "POST", base+"/complete", bTok, bytes.NewReader([]byte(`{"via":"lan"}`))); resp.StatusCode != 200 {
		t.Fatalf("lan complete: %d", resp.StatusCode)
	}
	if ev := wa.expect("transfer.complete"); ev["mode"] != "lan" || ev["status"] != "COMPLETED" {
		t.Fatalf("complete event: %v", ev)
	}
}
