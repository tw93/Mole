package main

import (
	"errors"
	"testing"
)

func TestOnDiskSize(t *testing.T) {
	calls := 0
	allocated := func(n int64, err error) func(string) (int64, error) {
		return func(string) (int64, error) { calls++; return n, err }
	}
	cases := []struct {
		name  string
		attrs uint32
		alloc func(string) (int64, error)
		want  int64
		calls int
	}{
		{"ordinary file keeps its length without a query", 0x20, allocated(1, nil), 1000, 0},
		{"recall-on-open placeholder is never queried", attrRecallOnOpen, allocated(1000, nil), 0, 0},
		{"OneDrive online-only file is never queried", attrRecallOnDataAccess | attrOffline, allocated(1000, nil), 0, 0},
		{"partly downloaded placeholder uses its allocation", attrRecallOnDataAccess | attrSparse, allocated(300, nil), 300, 1},
		{"unanswered placeholder is not local data", attrRecallOnDataAccess, allocated(0, errors.New("denied")), 0, 1},
		{"sparse image uses its allocation", attrSparse, allocated(400, nil), 400, 1},
		{"compressed file uses its compressed size", attrCompressed, allocated(250, nil), 250, 1},
		{"unanswered compressed file keeps its length", attrCompressed, allocated(0, errors.New("gone")), 1000, 1},
		{"allocation never exceeds the length", attrSparse, allocated(8192, nil), 1000, 1},
	}
	for _, tc := range cases {
		calls = 0
		if got := onDiskSize(`C:\x`, 1000, tc.attrs, tc.alloc); got != tc.want || calls != tc.calls {
			t.Errorf("%s: got %d after %d queries, want %d after %d", tc.name, got, calls, tc.want, tc.calls)
		}
	}
}
