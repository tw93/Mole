package main

import "testing"

func TestParseMemoryPSI(t *testing.T) {
	raw := "some avg10=1.50 avg60=3.25 avg300=0.40 total=123456\nfull avg10=0.10 avg60=0.20 avg300=0.05 total=2345\n"
	psi, ok := parseMemoryPSI(raw)
	if !ok {
		t.Fatal("parseMemoryPSI() ok = false")
	}
	want := MemoryPressureStats{SomeAvg10: 1.5, SomeAvg60: 3.25, FullAvg10: 0.1, FullAvg60: 0.2}
	if psi != want {
		t.Fatalf("parseMemoryPSI() = %#v, want %#v", psi, want)
	}
}

func TestParseMemoryPSIRejectsGarbage(t *testing.T) {
	for _, raw := range []string{"", "not psi\n", "some avg10=oops avg60=x\n"} {
		if _, ok := parseMemoryPSI(raw); ok {
			t.Fatalf("parseMemoryPSI(%q) ok = true, want false", raw)
		}
	}
}

func TestReadMemoryPSIFromRoot(t *testing.T) {
	root := writeTree(t, map[string]string{
		"proc/pressure/memory": "some avg10=12.00 avg60=6.00 avg300=1.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n",
	})
	psi, ok := readMemoryPSI(root)
	if !ok || psi.SomeAvg10 != 12 {
		t.Fatalf("readMemoryPSI() = %#v, %v", psi, ok)
	}
	if _, ok := readMemoryPSI(t.TempDir()); ok {
		t.Fatal("readMemoryPSI() ok = true on a kernel without PSI")
	}
}

func TestClassifyMemoryPressure(t *testing.T) {
	tests := []struct {
		name string
		psi  MemoryPressureStats
		want string
	}{
		{"idle", MemoryPressureStats{}, "normal"},
		{"noise", MemoryPressureStats{SomeAvg10: 2, SomeAvg60: 1}, "normal"},
		{"some avg10 warn", MemoryPressureStats{SomeAvg10: 10}, "warn"},
		{"some avg60 warn", MemoryPressureStats{SomeAvg60: 5}, "warn"},
		{"full avg10 warn", MemoryPressureStats{FullAvg10: 1}, "warn"},
		{"some avg10 critical", MemoryPressureStats{SomeAvg10: 40}, "critical"},
		{"full avg10 critical", MemoryPressureStats{FullAvg10: 5}, "critical"},
		{"some avg60 critical", MemoryPressureStats{SomeAvg60: 25}, "critical"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := classifyMemoryPressure(tt.psi); got != tt.want {
				t.Fatalf("classifyMemoryPressure(%#v) = %q, want %q", tt.psi, got, tt.want)
			}
		})
	}
}
