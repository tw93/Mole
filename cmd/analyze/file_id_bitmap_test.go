package main

import (
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
)

func TestRecordBitmapAddsEachRecordOnceUnderConcurrency(t *testing.T) {
	var bitmap recordBitmap
	const records = 600_000
	var fresh atomic.Int64
	var wg sync.WaitGroup
	for worker := 0; worker < 8; worker++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for record := uint64(0); record < records; record++ {
				if bitmap.add(record) {
					fresh.Add(1)
				}
			}
		}()
	}
	wg.Wait()
	if fresh.Load() != records {
		t.Fatalf("%d records reported new, want %d", fresh.Load(), records)
	}
	if bitmap.add(records - 1) {
		t.Fatal("a record already set reported new")
	}
}

func TestRecordBitmapHoldsAMillionRecordsInKilobytes(t *testing.T) {
	var bitmap recordBitmap
	for record := uint64(0); record < 1_000_000; record++ {
		bitmap.add(record)
	}
	// Four 32 KiB pages cover records 0 to 1,048,575.
	if got := bitmap.footprintBytes(); got != 4*32*1024 {
		t.Fatalf("footprint = %d bytes, want 131072", got)
	}
	// A record far up a sparse MFT creates only its own page.
	bitmap.add(40 << recordPageShift)
	if got := bitmap.footprintBytes(); got != 5*32*1024 {
		t.Fatalf("footprint after a distant record = %d bytes, want 163840", got)
	}
}

func TestCountFileKeepsNTFSReferencesInTheBitmap(t *testing.T) {
	path := filepath.Join(t.TempDir(), "file.bin")
	if err := os.WriteFile(path, make([]byte, 4096), 0o644); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	entry := func(volume uint32, id uint64, ntfs bool) scanDirEntry {
		return scanDirEntry{record: &idBothDirEntry{Name: "file.bin", VolumeSerial: volume, FileID: id, FileReference: ntfs}}
	}
	limiter := newScanLimiter(0)
	const record = 0x1234
	sequenced := uint64(7)<<48 | record

	cases := []struct {
		name  string
		entry scanDirEntry
		want  int64
	}{
		{"first NTFS link", entry(1, sequenced, true), 4096},
		{"second NTFS link to the same record", entry(1, sequenced, true), 0},
		{"same record on another volume", entry(2, sequenced, true), 4096},
		{"ReFS ID", entry(3, record, false), 4096},
		{"same ReFS ID again", entry(3, record, false), 0},
	}
	for _, c := range cases {
		if got, _ := limiter.countFile(path, c.entry, info); got != c.want {
			t.Fatalf("%s counted %d, want %d", c.name, got, c.want)
		}
	}
	held := 0
	for i := range limiter.seen {
		for _, files := range limiter.seen[i].volumes {
			held += len(files)
		}
	}
	if held != 1 {
		t.Fatalf("hashed set holds %d IDs, want only the ReFS one", held)
	}
}
