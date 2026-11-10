package units

import "testing"

func TestBytesSI(t *testing.T) {
	tests := []struct {
		input int64
		want  string
	}{
		{-100, "0 B"},
		{0, "0 B"},
		{512, "512 B"},
		{999, "999 B"},
		{1000, "1.0 kB"},
		{1500, "1.5 kB"},
		{10000, "10.0 kB"},
		{999949, "999.9 kB"},
		{999950, "1.0 MB"},
		{999960, "1.0 MB"},
		{999999, "1.0 MB"},
		{1000000, "1.0 MB"},
		{1500000, "1.5 MB"},
		{999949999, "999.9 MB"},
		{999950000, "1.0 GB"},
		{1000000000, "1.0 GB"},
		{999999999999, "1.0 TB"},
		{1000000000000, "1.0 TB"},
		{1000000000000000, "1.0 PB"},
	}

	for _, tt := range tests {
		got := BytesSI(tt.input)
		if got != tt.want {
			t.Errorf("BytesSI(%d) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestBytesBin(t *testing.T) {
	tests := []struct {
		name  string
		input uint64
		want  string
	}{
		{"zero", 0, "0 B"},
		{"one byte", 1, "1 B"},
		{"1023 bytes", 1023, "1023 B"},

		{"exactly 1KB", 1 << 10, "1024 B"},
		{"just over 1KB", (1 << 10) + 1, "1.0 KB"},
		{"1.5KB", 1536, "1.5 KB"},

		{"999 bytes", 999, "999 B"},
		{"exactly 1MB", 1 << 20, "1024.0 KB"},
		{"just under 1MB stays in KB by design", (1 << 20) - 1, "1024.0 KB"},
		{"just over 1MB", (1 << 20) + 1, "1.0 MB"},
		{"500MB", 500 << 20, "500.0 MB"},

		{"exactly 1GB", 1 << 30, "1024.0 MB"},
		{"just over 1GB", (1 << 30) + 1, "1.0 GB"},
		{"100GB", 100 << 30, "100.0 GB"},

		{"exactly 1TB", 1 << 40, "1024.0 GB"},
		{"just over 1TB", (1 << 40) + 1, "1.0 TB"},
		{"2TB", 2 << 40, "2.0 TB"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := BytesBin(tt.input)
			if got != tt.want {
				t.Errorf("BytesBin(%d) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestBytesBinShort(t *testing.T) {
	tests := []struct {
		name  string
		input uint64
		want  string
	}{
		{"zero", 0, "0"},
		{"one byte", 1, "1"},
		{"999 bytes", 999, "999"},

		{"exactly 1KB", 1 << 10, "1K"},
		{"just under 1KB", (1 << 10) - 1, "1023"},
		{"1.5KB rounds to 2K", 1536, "2K"},
		{"999KB", 999 << 10, "999K"},

		{"exactly 1MB", 1 << 20, "1M"},
		{"just under 1MB", (1 << 20) - 1, "1M"},
		{"rounds below 1024K", 1023*1024 + 511, "1023K"},
		{"rounds up to 1M", 1023*1024 + 512, "1M"},
		{"500MB", 500 << 20, "500M"},

		{"exactly 1GB", 1 << 30, "1G"},
		{"just under 1GB", (1 << 30) - 1, "1G"},
		{"100GB", 100 << 30, "100G"},

		{"exactly 1TB", 1 << 40, "1T"},
		{"just under 1TB", (1 << 40) - 1, "1T"},
		{"2TB", 2 << 40, "2T"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := BytesBinShort(tt.input)
			if got != tt.want {
				t.Errorf("BytesBinShort(%d) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestBytesBinCompact(t *testing.T) {
	tests := []struct {
		name  string
		input uint64
		want  string
	}{
		{"zero", 0, "0"},
		{"one byte", 1, "1"},
		{"1023 bytes", 1023, "1023"},

		{"exactly 1KB", 1 << 10, "1.0K"},
		{"1.5KB", 1536, "1.5K"},
		{"below the step", 1023*1024 + 972, "1023.9K"},
		{"rounds up to 1.0M", 1023*1024 + 973, "1.0M"},
		{"just under 1MB", (1 << 20) - 1, "1.0M"},
		{"just under 1GB", (1 << 30) - 1, "1.0G"},
		{"just under 1TB", (1 << 40) - 1, "1.0T"},

		{"exactly 1MB", 1 << 20, "1.0M"},
		{"500MB", 500 << 20, "500.0M"},

		{"exactly 1GB", 1 << 30, "1.0G"},
		{"100GB", 100 << 30, "100.0G"},

		{"exactly 1TB", 1 << 40, "1.0T"},
		{"2TB", 2 << 40, "2.0T"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := BytesBinCompact(tt.input)
			if got != tt.want {
				t.Errorf("BytesBinCompact(%d) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}
