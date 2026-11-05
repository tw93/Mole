package main

import (
	"encoding/gob"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestStampWithinTreatsFutureStampAsExpired(t *testing.T) {
	now := time.Now()
	cases := []struct {
		name  string
		stamp time.Time
		want  bool
	}{
		{"fresh", now.Add(-time.Hour), true},
		{"just stamped", now, true},
		{"expired", now.Add(-48 * time.Hour), false},
		{"future", now.Add(time.Hour), false},
	}
	for _, tc := range cases {
		if got := stampWithin(now, tc.stamp, 24*time.Hour); got != tc.want {
			t.Errorf("%s: stampWithin = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestOverviewSnapshotFromTheFutureIsNotServed(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()

	storePath, err := getOverviewSizeStorePath()
	if err != nil {
		t.Fatalf("getOverviewSizeStorePath: %v", err)
	}
	seeded := map[string]overviewSizeSnapshot{
		"/future": {Size: 1 << 20, Updated: time.Now().Add(24 * time.Hour), SchemaVersion: cacheSchemaVersion},
	}
	data, err := json.Marshal(seeded)
	if err != nil {
		t.Fatalf("marshal seed: %v", err)
	}
	if err := os.WriteFile(storePath, data, 0o644); err != nil {
		t.Fatalf("write seed: %v", err)
	}

	if _, err := loadStoredOverviewSize("/future"); err == nil {
		t.Fatalf("a snapshot stamped in the future must read as expired")
	}
}

func TestScanCacheFromTheFutureIsNotServed(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "future-cache-target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}
	if err := saveCacheToDisk(target, scanResult{TotalSize: 9, TotalFiles: 3}); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}
	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}
	file, err := os.Open(cachePath)
	if err != nil {
		t.Fatalf("open cache: %v", err)
	}
	var entry cacheEntry
	if err := gob.NewDecoder(file).Decode(&entry); err != nil {
		t.Fatalf("decode cache: %v", err)
	}
	_ = file.Close()
	entry.ScanTime = time.Now().Add(24 * time.Hour)
	f, err := os.Create(cachePath)
	if err != nil {
		t.Fatalf("rewrite cache: %v", err)
	}
	if err := gob.NewEncoder(f).Encode(&entry); err != nil {
		t.Fatalf("encode cache: %v", err)
	}
	_ = f.Close()
	if err := os.Chtimes(target, time.Now().Add(-time.Hour), time.Now().Add(-time.Hour)); err != nil {
		t.Fatalf("chtimes target: %v", err)
	}

	if _, err := loadStaleCacheFromDisk(target); err == nil {
		t.Fatalf("a scan stamped in the future must not serve first paint")
	}
	if _, err := loadCacheFromDisk(target); err == nil {
		t.Fatalf("a scan stamped in the future must not count as current")
	}
}
