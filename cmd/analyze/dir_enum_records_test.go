package main

// These tests run on every platform, including a Linux developer machine or a
// macOS checkout. They decode buffers built by hand to prove the record walk
// matches the layout the file system writes.

import (
	"encoding/binary"
	"errors"
	"strings"
	"testing"
	"time"
	"unicode/utf16"
	"unsafe"
)

type testDirRecord struct {
	name       string
	fileID     uint64
	size       uint64
	allocation uint64
	attributes uint32
	reparseTag uint32
}

// encodeIDBothDirBuffer builds one buffer the way the file system does: records
// back to back, each padded to 8 bytes, and every NextEntryOffset set except the
// last. The caller can then corrupt a field to test a rejection path.
func encodeIDBothDirBuffer(records []testDirRecord) []byte {
	sizes := make([]int, len(records))
	total := 0
	for index, record := range records {
		body := idBothDirNameOffset + 2*len(utf16.Encode([]rune(record.name)))
		sizes[index] = (body + 7) &^ 7
		total += sizes[index]
	}

	buffer := make([]byte, total)
	offset := 0
	for index, record := range records {
		name := utf16.Encode([]rune(record.name))
		encoded := (*idBothDirRecord)(unsafe.Pointer(&buffer[offset]))
		encoded.FileIndex = uint32(index)
		encoded.EndOfFile = record.size
		encoded.AllocationSize = record.allocation
		encoded.FileAttributes = record.attributes
		encoded.FileNameLength = uint32(2 * len(name))
		encoded.EaSize = record.reparseTag
		encoded.FileID = record.fileID
		if index == len(records)-1 {
			encoded.NextEntryOffset = 0
		} else {
			encoded.NextEntryOffset = uint32(sizes[index])
		}
		copy(unsafe.Slice(&encoded.FileName[0], len(name)), name)
		offset += sizes[index]
	}
	return buffer
}

func collectIDBothDirEntries(t *testing.T, buffer []byte) []idBothDirEntry {
	t.Helper()
	var entries []idBothDirEntry
	if err := walkIDBothDirBuffer(buffer, func(entry idBothDirEntry) error {
		entries = append(entries, entry)
		return nil
	}); err != nil {
		t.Fatalf("walkIDBothDirBuffer returned %v", err)
	}
	return entries
}

func TestIDBothDirRecordLayoutMatchesWin32Offsets(t *testing.T) {
	offsets := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		{"EndOfFile", unsafe.Offsetof(idBothDirRecord{}.EndOfFile), 40},
		{"AllocationSize", unsafe.Offsetof(idBothDirRecord{}.AllocationSize), 48},
		{"FileAttributes", unsafe.Offsetof(idBothDirRecord{}.FileAttributes), 56},
		{"FileNameLength", unsafe.Offsetof(idBothDirRecord{}.FileNameLength), 60},
		{"EaSize", unsafe.Offsetof(idBothDirRecord{}.EaSize), 64},
		{"FileID", unsafe.Offsetof(idBothDirRecord{}.FileID), 96},
		{"FileName", unsafe.Offsetof(idBothDirRecord{}.FileName), idBothDirNameOffset},
	}
	for _, offset := range offsets {
		if offset.got != offset.want {
			t.Errorf("%s offset = %d, want %d", offset.name, offset.got, offset.want)
		}
	}
}

func TestWalkIDBothDirBufferDecodesEveryField(t *testing.T) {
	buffer := encodeIDBothDirBuffer([]testDirRecord{
		{name: "a.bin", fileID: 0x8000_0000_0000_0001, size: 4096, allocation: 4096, attributes: 0x20},
		{name: "项目 数据", fileID: 42, size: 9_000_000_000, allocation: 1_048_576, attributes: 0x120},
		{name: "junction", fileID: 7, size: 0, allocation: 0, attributes: 0x400, reparseTag: 0xA0000003},
	})

	entries := collectIDBothDirEntries(t, buffer)
	if len(entries) != 3 {
		t.Fatalf("decoded %d entries, want 3", len(entries))
	}
	first := entries[0]
	if first.Name != "a.bin" || first.FileID != 0x8000_0000_0000_0001 || first.Size != 4096 || first.AllocationSize != 4096 {
		t.Errorf("first entry = %+v", first)
	}
	second := entries[1]
	if second.Name != "项目 数据" || second.Size != 9_000_000_000 || second.AllocationSize != 1_048_576 {
		t.Errorf("second entry = %+v", second)
	}
	if second.Attributes != 0x120 {
		t.Errorf("second attributes = %#x, want 0x120", second.Attributes)
	}
	third := entries[2]
	if third.ReparseTag != 0xA0000003 {
		t.Errorf("reparse tag = %#x, want 0xa0000003", third.ReparseTag)
	}
}

func TestWalkIDBothDirBufferSkipsDotEntriesAndKeepsHiddenNames(t *testing.T) {
	buffer := encodeIDBothDirBuffer([]testDirRecord{
		{name: ".", fileID: 1},
		{name: "..", fileID: 2},
		{name: ".hidden", fileID: 3},
		{name: "..leading-dots.txt", fileID: 4},
	})

	entries := collectIDBothDirEntries(t, buffer)
	if len(entries) != 2 {
		t.Fatalf("decoded %d entries, want 2", len(entries))
	}
	if entries[0].Name != ".hidden" || entries[1].Name != "..leading-dots.txt" {
		t.Fatalf("decoded names = %q, %q", entries[0].Name, entries[1].Name)
	}
}

func TestWalkIDBothDirBufferAcceptsEmptyBuffer(t *testing.T) {
	if err := walkIDBothDirBuffer(nil, func(idBothDirEntry) error {
		t.Fatal("visit called for an empty buffer")
		return nil
	}); err != nil {
		t.Fatalf("empty buffer returned %v", err)
	}
}

func TestWalkIDBothDirBufferPropagatesVisitError(t *testing.T) {
	sentinel := errors.New("stop")
	buffer := encodeIDBothDirBuffer([]testDirRecord{{name: "a", fileID: 1}, {name: "b", fileID: 2}})

	err := walkIDBothDirBuffer(buffer, func(idBothDirEntry) error { return sentinel })
	if !errors.Is(err, sentinel) {
		t.Fatalf("walk returned %v, want the visit error", err)
	}
}

func TestWalkIDBothDirBufferRejectsBrokenLayouts(t *testing.T) {
	valid := func() []byte {
		return encodeIDBothDirBuffer([]testDirRecord{{name: "a.bin", fileID: 1}, {name: "b.bin", fileID: 2}})
	}
	first := func(buffer []byte) *idBothDirRecord {
		return (*idBothDirRecord)(unsafe.Pointer(&buffer[0]))
	}
	pointAtFakeRecord := func(next uint32) []byte {
		buffer := valid()
		first(buffer).NextEntryOffset = next
		binary.LittleEndian.PutUint32(buffer[int(next):], 0)
		binary.LittleEndian.PutUint32(buffer[int(next)+60:], 2)
		binary.LittleEndian.PutUint16(buffer[int(next)+idBothDirNameOffset:], 'x')
		return buffer
	}

	cases := []struct {
		name   string
		mutate func() []byte
	}{
		{"truncated fixed part", func() []byte { return valid()[:idBothDirNameOffset-1] }},
		{"zero name length", func() []byte {
			buffer := valid()
			first(buffer).FileNameLength = 0
			return buffer
		}},
		{"odd name length", func() []byte {
			buffer := valid()
			first(buffer).FileNameLength = 3
			return buffer
		}},
		{"name runs past buffer", func() []byte {
			buffer := valid()
			first(buffer).FileNameLength = uint32(len(buffer))
			return buffer
		}},
		{"next offset inside fixed part", func() []byte {
			buffer := valid()
			first(buffer).NextEntryOffset = idBothDirNameOffset - 1
			return buffer
		}},
		{"next offset inside name", func() []byte { return pointAtFakeRecord(112) }},
		{"next offset is not aligned", func() []byte { return pointAtFakeRecord(121) }},
		{"next offset past buffer", func() []byte {
			buffer := valid()
			first(buffer).NextEntryOffset = uint32(len(buffer) + 1)
			return buffer
		}},
		{"next offset leaves a stub", func() []byte {
			buffer := valid()
			first(buffer).NextEntryOffset = uint32(len(buffer) - idBothDirNameOffset + 1)
			return buffer
		}},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			err := walkIDBothDirBuffer(testCase.mutate(), func(idBothDirEntry) error { return nil })
			if err == nil {
				t.Fatal("walk accepted a broken buffer")
			}
			var malformed *malformedDirBufferError
			if !errors.As(err, &malformed) {
				t.Fatalf("error = %v, want malformedDirBufferError", err)
			}
			if strings.TrimSpace(malformed.Error()) == "" {
				t.Fatal("malformed error carries no reason")
			}
		})
	}
}

func TestFiletimeToTimeRoundTrips(t *testing.T) {
	want := time.Date(2026, time.November, 15, 10, 30, 15, 500_000_000, time.UTC)
	ticks := want.Unix()*filetimeTicksPerSecond + int64(want.Nanosecond())/100 + filetimeUnixEpoch
	stamp := fileTimestamp{LowDateTime: uint32(ticks), HighDateTime: uint32(uint64(ticks) >> 32)}

	if got := filetimeToTime(stamp); !got.Equal(want) {
		t.Fatalf("filetimeToTime = %s, want %s", got, want)
	}
	if got := filetimeToTime(fileTimestamp{}); !got.IsZero() {
		t.Fatalf("zero FILETIME decoded as %s, want the zero time", got)
	}
	before1970 := fileTimestamp{LowDateTime: 1, HighDateTime: 0}
	if got := filetimeToTime(before1970); !got.IsZero() {
		t.Fatalf("pre-epoch FILETIME decoded as %s, want the zero time", got)
	}
}
