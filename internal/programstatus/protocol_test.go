package programstatus

import (
	"strings"
	"testing"
)

func TestEncodeRecord(t *testing.T) {
	record := Record{State: StateBlocked, Kind: KindPermission, App: "mole", Title: "mole analyze"}
	sequence, err := record.Encode()
	want := "\x1b]7501;state=blocked:kind=permission:app=mole:title=bW9sZSBhbmFseXpl\x1b\\"
	if err != nil || sequence != want {
		t.Fatalf("Encode() = %q, %v; want %q", sequence, err, want)
	}
	for _, kind := range []Kind{KindPermission, KindQuestion, KindAuth} {
		if _, err := (Record{State: StateBlocked, Kind: kind}).Encode(); err != nil {
			t.Errorf("Encode rejected kind %q: %v", kind, err)
		}
	}
	if _, err := (Record{State: StateDone}).Encode(); err != nil {
		t.Errorf("Encode rejected state %q: %v", StateDone, err)
	}
	record.State = StateClear
	sequence, err = record.Encode()
	if err != nil || strings.Contains(sequence, ":kind=") {
		t.Fatalf("clear included state-specific fields: %q, %v", sequence, err)
	}
}

func TestEncodeRejectsInvalidFields(t *testing.T) {
	for _, record := range []Record{
		{State: "blocked:kind=permission"},
		{State: StateBlocked, Kind: "unknown"},
		{State: StateWorking, App: "mole:kind=auth"},
		{State: StateWorking, Title: strings.Repeat("é", 97)},
		{State: StateWorking, Title: "hello\x1b"},
	} {
		if sequence, err := record.Encode(); sequence != "" || err == nil {
			t.Errorf("Encode(%+v) = %q, %v", record, sequence, err)
		}
	}
}
