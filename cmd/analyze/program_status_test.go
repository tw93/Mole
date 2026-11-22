package main

import (
	"testing"

	"github.com/tw93/mole/internal/programstatus"
)

func TestProgramStateFollowsModelActivity(t *testing.T) {
	for _, test := range []struct {
		name  string
		model model
		state programstatus.State
		kind  programstatus.Kind
	}{
		{"idle browsing", model{path: "/Users/test"}, programstatus.StateIdle, ""},
		{"scanning a directory", model{path: "/Users/test", scanning: true}, programstatus.StateWorking, ""},
		{"deleting", model{path: "/Users/test", deleting: true}, programstatus.StateWorking, ""},
		{"overview still measuring", model{path: "/", isOverview: true, overviewScanning: true}, programstatus.StateWorking, ""},
		{"overview flag outside overview", model{path: "/Users/test", overviewScanning: true}, programstatus.StateIdle, ""},
		{"overview finished", model{path: "/", isOverview: true}, programstatus.StateIdle, ""},
		{"waiting for delete confirmation", model{path: "/Users/test", deleteConfirm: true}, programstatus.StateBlocked, programstatus.KindPermission},
		{"confirmation wins over a scan", model{path: "/Users/test", deleteConfirm: true, scanning: true}, programstatus.StateBlocked, programstatus.KindPermission},
	} {
		state, kind := test.model.programState()
		if state != test.state || kind != test.kind {
			t.Errorf("%s: programState() = %q, %q; want %q, %q", test.name, state, kind, test.state, test.kind)
		}
	}
}
