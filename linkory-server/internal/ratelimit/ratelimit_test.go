package ratelimit

import (
	"testing"
	"time"
)

func TestLimiterBlocksAfterMaxAndResets(t *testing.T) {
	l := New(time.Minute, 3)
	for i := 0; i < 2; i++ {
		l.Fail("a")
	}
	if l.Blocked("a") {
		t.Fatal("blocked before reaching the limit")
	}
	l.Fail("a")
	if !l.Blocked("b", "a") {
		t.Fatal("not blocked at the limit")
	}
	l.Reset("a")
	if l.Blocked("a") {
		t.Fatal("still blocked after reset")
	}
}

func TestLimiterWindowExpiresAndPrunes(t *testing.T) {
	l := New(20*time.Millisecond, 1)
	l.Fail("a", "b")
	if !l.Blocked("a") {
		t.Fatal("expected block")
	}
	time.Sleep(40 * time.Millisecond)
	if l.Blocked("a") {
		t.Fatal("failure should have left the window")
	}
	l.Prune()
	if len(l.failures) != 0 {
		t.Fatalf("prune left %d keys", len(l.failures))
	}
}
