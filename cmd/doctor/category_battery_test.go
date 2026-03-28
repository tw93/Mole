package main

import "testing"

func TestParseIORegInt(t *testing.T) {
	tests := []struct {
		name   string
		output string
		key    string
		want   int
	}{
		{
			name:   "standard cycle count",
			output: "    \"CycleCount\" = 150\n    \"MaxCapacity\" = 100\n",
			key:    "CycleCount",
			want:   150,
		},
		{
			name:   "max capacity",
			output: "    \"MaxCapacity\" = 100\n",
			key:    "MaxCapacity",
			want:   100,
		},
		{
			name:   "design capacity",
			output: "    \"DesignCapacity\" = 6249\n    \"AppleRawMaxCapacity\" = 6092\n",
			key:    "DesignCapacity",
			want:   6249,
		},
		{
			name:   "apple raw max capacity",
			output: "    \"DesignCapacity\" = 6249\n    \"AppleRawMaxCapacity\" = 6092\n",
			key:    "AppleRawMaxCapacity",
			want:   6092,
		},
		{
			name:   "key not found",
			output: "    \"CycleCount\" = 150\n",
			key:    "MaxCapacity",
			want:   -1,
		},
		{
			name:   "empty output",
			output: "",
			key:    "CycleCount",
			want:   -1,
		},
		{
			name:   "malformed value",
			output: "    \"CycleCount\" = abc\n",
			key:    "CycleCount",
			want:   -1,
		},
		{
			name:   "zero value",
			output: "    \"CycleCount\" = 0\n",
			key:    "CycleCount",
			want:   0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseIORegInt(tt.output, tt.key)
			if got != tt.want {
				t.Errorf("parseIORegInt(%q, %q) = %d, want %d", tt.output, tt.key, got, tt.want)
			}
		})
	}
}

func TestCheckBatteryCycles(t *testing.T) {
	tests := []struct {
		name       string
		ioregOut   string
		wantStatus checkStatus
		wantMin    int
		wantMax    int
	}{
		{
			name:       "low cycles",
			ioregOut:   "    \"CycleCount\" = 50\n",
			wantStatus: statusPass,
			wantMin:    10,
			wantMax:    10,
		},
		{
			name:       "medium cycles",
			ioregOut:   "    \"CycleCount\" = 600\n",
			wantStatus: statusWarn,
			wantMin:    7,
			wantMax:    7,
		},
		{
			name:       "high cycles",
			ioregOut:   "    \"CycleCount\" = 1000\n",
			wantStatus: statusFail,
			wantMin:    2,
			wantMax:    2,
		},
		{
			name:       "missing cycle count",
			ioregOut:   "    \"MaxCapacity\" = 100\n",
			wantStatus: statusSkipped,
			wantMin:    0,
			wantMax:    0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := checkBatteryCycles(tt.ioregOut)
			if r.Status != tt.wantStatus {
				t.Errorf("checkBatteryCycles() status = %d, want %d", r.Status, tt.wantStatus)
			}
			if r.Score < tt.wantMin || r.Score > tt.wantMax {
				t.Errorf("checkBatteryCycles() score = %d, want [%d, %d]", r.Score, tt.wantMin, tt.wantMax)
			}
		})
	}
}

func TestCheckBatteryHealth(t *testing.T) {
	tests := []struct {
		name       string
		ioregOut   string
		wantStatus checkStatus
	}{
		{
			name:       "healthy battery raw capacity",
			ioregOut:   "    \"AppleRawMaxCapacity\" = 6000\n    \"DesignCapacity\" = 6249\n",
			wantStatus: statusPass,
		},
		{
			name:       "degraded battery",
			ioregOut:   "    \"AppleRawMaxCapacity\" = 5300\n    \"DesignCapacity\" = 6249\n",
			wantStatus: statusWarn,
		},
		{
			name:       "bad battery",
			ioregOut:   "    \"AppleRawMaxCapacity\" = 4500\n    \"DesignCapacity\" = 6249\n",
			wantStatus: statusFail,
		},
		{
			name:       "missing capacity data",
			ioregOut:   "    \"CycleCount\" = 50\n",
			wantStatus: statusSkipped,
		},
		{
			name:       "fallback to MaxCapacity",
			ioregOut:   "    \"MaxCapacity\" = 95\n    \"DesignCapacity\" = 100\n",
			wantStatus: statusPass,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := checkBatteryHealth(tt.ioregOut)
			if r.Status != tt.wantStatus {
				t.Errorf("checkBatteryHealth() status = %d, want %d", r.Status, tt.wantStatus)
			}
		})
	}
}
