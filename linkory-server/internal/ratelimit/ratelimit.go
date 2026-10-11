// Package ratelimit is a small in-memory sliding-window failure counter used to throttle login and
// password guessing. State is per process (single instance), like the rest of the server.
package ratelimit

import (
	"sync"
	"time"
)

// Defaults shared by the user and admin login throttles.
const (
	DefaultWindow      = 5 * time.Minute
	DefaultMaxFailures = 5
)

// pruneThreshold bounds memory: once this many keys are tracked, Fail sweeps expired ones.
const pruneThreshold = 1024

type Limiter struct {
	window time.Duration
	max    int

	mu       sync.Mutex
	failures map[string][]time.Time
}

func New(window time.Duration, max int) *Limiter {
	return &Limiter{window: window, max: max, failures: map[string][]time.Time{}}
}

// Blocked reports whether any of keys has reached the failure limit inside the window.
func (l *Limiter) Blocked(keys ...string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, k := range keys {
		if len(l.recentLocked(k)) >= l.max {
			return true
		}
	}
	return false
}

// Fail records one failure against every key.
func (l *Limiter) Fail(keys ...string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.failures) >= pruneThreshold {
		l.pruneLocked()
	}
	now := time.Now()
	for _, k := range keys {
		l.failures[k] = append(l.recentLocked(k), now)
	}
}

// Reset forgets the failures of keys (after a successful login).
func (l *Limiter) Reset(keys ...string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for _, k := range keys {
		delete(l.failures, k)
	}
}

// Prune drops every key whose failures have all left the window.
func (l *Limiter) Prune() {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.pruneLocked()
}

func (l *Limiter) pruneLocked() {
	for k := range l.failures {
		l.recentLocked(k)
	}
}

// recentLocked trims key to the failures inside the window, deleting it when none remain.
func (l *Limiter) recentLocked(key string) []time.Time {
	cut := time.Now().Add(-l.window)
	list := l.failures[key]
	kept := list[:0:0]
	for _, t := range list {
		if t.After(cut) {
			kept = append(kept, t)
		}
	}
	if len(kept) == 0 {
		delete(l.failures, key)
		return nil
	}
	l.failures[key] = kept
	return kept
}
