package main

import "testing"

func TestPadCellAlignsCJK(t *testing.T) {
	for in, want := range map[string]string{"启用": "启用    ", "已禁用": "已禁用  ", "admin": "admin   ", "toolongvalue": "toolongvalue "} {
		if got := padCell(in, 8); got != want {
			t.Errorf("padCell(%q) = %q, want %q", in, got, want)
		}
	}
}
