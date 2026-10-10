package admin

import (
	"net/http/httptest"
	"runtime"
	"testing"
	"time"
)

func TestProxyOriginAndIPTrust(t *testing.T) {
	s := NewService(nil, nil, 30)
	r := httptest.NewRequest("POST", "http://admin.test/api/admin/v1/auth/login", nil)
	r.RemoteAddr = "127.0.0.1:9999"
	r.Header.Set("X-Forwarded-Proto", "https")
	r.Header.Set("Origin", "https://admin.test")
	r.Header.Set("X-Real-IP", "203.0.113.25")
	if !s.sameOrigin(r) || s.sourceIP(r) != "203.0.113.25" {
		t.Fatal("trusted local proxy not honored")
	}
	r.RemoteAddr = "203.0.113.9:9999"
	if s.sameOrigin(r) || s.sourceIP(r) != "203.0.113.9" {
		t.Fatal("untrusted forwarded headers honored")
	}
	r.RemoteAddr = "172.17.0.1:9999"
	if err := s.SetTrustedProxies([]string{"172.17.0.1/32"}); err != nil {
		t.Fatal(err)
	}
	if !s.sameOrigin(r) {
		t.Fatal("configured Docker proxy not honored")
	}
	r.Header.Set("Origin", "https://different.test")
	if s.sameOrigin(r) {
		t.Fatal("foreign origin accepted")
	}
	r.Header.Set("Origin", "https://user@admin.test")
	if s.sameOrigin(r) {
		t.Fatal("origin with userinfo accepted")
	}
	if err := s.SetTrustedProxies([]string{"not-a-cidr"}); err == nil {
		t.Fatal("invalid proxy configuration accepted")
	}
}
func TestManagementPasswords(t *testing.T) {
	pw := "管理员强密码至少十二个字符测试"
	hash := passwordHash(pw)
	if !verify(pw, hash) || verify("wrong", hash) || verify(pw, "invalid") {
		t.Fatal("password verification")
	}
}

func TestSampleMeasuresCPUBetweenReadings(t *testing.T) {
	s := NewService(nil, nil, 30)
	first := s.sample()
	if first.CPUPercent != 0 {
		t.Fatal("first reading has nothing to compare with", first.CPUPercent)
	}
	deadline := time.Now().Add(150 * time.Millisecond)
	for x := 0; time.Now().Before(deadline); x++ {
		_ = x * x
	}
	second := s.sample()
	if runtime.GOOS != "windows" && second.CPUPercent <= 0 {
		t.Fatal("busy loop not visible in CPU percent", second.CPUPercent)
	}
	if len(s.mon.history) != 2 {
		t.Fatal("history", len(s.mon.history))
	}
	for i := 0; i < monitorHistory+5; i++ {
		s.sample()
	}
	if len(s.mon.history) != monitorHistory {
		t.Fatal("history not capped", len(s.mon.history))
	}
}
