package main

import "testing"

func TestByteFormattersStepUpAtTheUnitBase(t *testing.T) {
	cases := []struct {
		name string
		fn   func(uint64) string
		in   uint64
		want string
	}{
		{"humanBytes ordinary", humanBytes, 1536, "1.5 KB"},
		{"humanBytes last in bytes", humanBytes, 1023, "1023 B"},
		{"humanBytes 1024 bytes", humanBytes, 1024, "1.0 KB"},
		{"humanBytes last in MB", humanBytes, 1073689395, "1023.9 MB"},
		{"humanBytes first to step up", humanBytes, 1073689396, "1.0 GB"},
		{"humanBytes one under 1 GB", humanBytes, 1<<30 - 1, "1.0 GB"},
		{"humanBytes exactly 1 GB", humanBytes, 1 << 30, "1.0 GB"},
		{"humanBytes largest unit stays", humanBytes, 1 << 50, "1024.0 TB"},

		{"humanBytesShort ordinary", humanBytesShort, 100 << 30, "100G"},
		{"humanBytesShort last in K", humanBytesShort, 1048063, "1023K"},
		{"humanBytesShort first to step up", humanBytesShort, 1048064, "1M"},
		{"humanBytesShort last in M", humanBytesShort, 1<<30 - 512*1024 - 1, "1023M"},
		{"humanBytesShort M steps up to G", humanBytesShort, 1<<30 - 512*1024, "1G"},
		{"humanBytesShort largest unit stays", humanBytesShort, 1 << 50, "1024T"},

		{"humanBytesCompact ordinary", humanBytesCompact, 1536, "1.5K"},
		{"humanBytesCompact last in K", humanBytesCompact, 1048524, "1023.9K"},
		{"humanBytesCompact first to step up", humanBytesCompact, 1048525, "1.0M"},
		{"humanBytesCompact one under 1 GB", humanBytesCompact, 1<<30 - 1, "1.0G"},
		{"humanBytesCompact largest unit stays", humanBytesCompact, 1 << 50, "1024.0T"},
	}
	for _, c := range cases {
		if got := c.fn(c.in); got != c.want {
			t.Errorf("%s: (%d) = %q, want %q", c.name, c.in, got, c.want)
		}
	}
}
