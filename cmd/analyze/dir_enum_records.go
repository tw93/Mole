package main

// This file holds the FILE_ID_BOTH_DIR_INFO layout and the walk that decodes
// one buffer of records. It carries no build tag on purpose: the layout and the
// bounds rules stay testable on every platform, while the Win32 calls live in
// dir_enum_windows.go.
//
// The layout must match the structure Go itself reads in
// src/internal/syscall/windows/syscall_windows.go. A drift would decode garbage
// from a buffer the file system wrote, so the size is pinned below and the field
// offsets are asserted in dir_enum_records_test.go.

import (
	"fmt"
	"time"
	"unicode/utf16"
	"unsafe"
)

// fileTimestamp mirrors syscall.Filetime as a fixed pair of 32-bit halves, so
// the record layout stays free of platform types. Field order and width match
// the Win32 structure.
type fileTimestamp struct {
	LowDateTime  uint32
	HighDateTime uint32
}

// idBothDirRecord is the fixed part of one FILE_ID_BOTH_DIR_INFO record plus
// the first UTF-16 unit of the name. The file system writes these records back
// to back into one buffer; NextEntryOffset is the distance to the next record,
// and zero marks the last record in the buffer.
//
// ShortNameLength is a CCHAR in the Win32 header. Widening it to uint32 here
// moves ShortName two bytes later. Every field this package reads keeps its
// Win32 offset, because 8-byte alignment already placed FileID at 96 and
// FileName at 104. Never read ShortName.
type idBothDirRecord struct {
	NextEntryOffset uint32
	FileIndex       uint32
	CreationTime    fileTimestamp
	LastAccessTime  fileTimestamp
	LastWriteTime   fileTimestamp
	ChangeTime      fileTimestamp
	EndOfFile       uint64
	AllocationSize  uint64
	FileAttributes  uint32
	FileNameLength  uint32
	EaSize          uint32
	ShortNameLength uint32
	ShortName       [12]uint16
	FileID          uint64
	FileName        [1]uint16
}

const (
	// idBothDirNameOffset is where the name starts inside a record.
	idBothDirNameOffset = 104
	// fileAttributeReparsePoint is FILE_ATTRIBUTE_REPARSE_POINT, spelled out
	// so the portable scanner can test it without the windows package.
	fileAttributeReparsePoint = 0x400
	// filetimeTicksPerSecond and filetimeUnixEpoch convert a FILETIME, which
	// counts 100 ns ticks since 1601-01-01, to Unix time.
	filetimeTicksPerSecond = int64(10_000_000)
	filetimeUnixEpoch      = int64(116_444_736_000_000_000)
)

// A layout drift must fail the build, not a scan. Each array length is zero
// only when the field sits at its Win32 offset. The offsets, not the size, are
// pinned: 386 aligns uint64 to 4 bytes, so its trailing padding differs.
var (
	_ = [1]struct{}{}[int(unsafe.Offsetof(idBothDirRecord{}.FileID))-96]
	_ = [1]struct{}{}[int(unsafe.Offsetof(idBothDirRecord{}.FileName))-idBothDirNameOffset]
)

// idBothDirRecordSlack is how far the fixed structure can reach past the last
// record's name. The walker views each record through the full structure, so
// a buffer keeps this many spare bytes after the region the file system fills.
const idBothDirRecordSlack = int(unsafe.Sizeof(idBothDirRecord{})) - idBothDirNameOffset

// idBothDirEntry is one decoded directory entry. FileID is zero and
// AllocationSize is zero when the entry came from the os.ReadDir fallback,
// which cannot report either.
type idBothDirEntry struct {
	Name         string
	VolumeSerial uint32
	// FileReference is true on NTFS, where FileID is a file reference whose
	// low 48 bits are the dense MFT record number.
	FileReference  bool
	FileID         uint64
	Size           int64
	AllocationSize int64
	Attributes     uint32
	// ReparseTag is meaningful only when Attributes carries
	// FILE_ATTRIBUTE_REPARSE_POINT. For every other entry EaSize holds the
	// size of the extended attributes, which is normally zero.
	ReparseTag     uint32
	CreationTime   fileTimestamp
	LastAccessTime fileTimestamp
	LastWriteTime  fileTimestamp
}

// decodeDirName turns one UTF-16 name into a string. The Windows build installs
// syscall.UTF16ToString, which decodes without the rune-slice copy the portable
// version needs; the portable version keeps the layout walk testable on every
// platform.
var decodeDirName = portableUTF16ToString

func portableUTF16ToString(units []uint16) string {
	return string(utf16.Decode(units))
}

// malformedDirBufferError reports a buffer that cannot be decoded.
type malformedDirBufferError struct {
	reason string
}

func (e *malformedDirBufferError) Error() string {
	return "malformed directory record buffer: " + e.reason
}

// walkIDBothDirBuffer decodes every record in buf and calls visit for each
// entry, skipping the "." and ".." entries the way os.ReadDir does. It returns
// at the first error, including a broken NextEntryOffset or a name that runs
// past the buffer: a silent skip would drop bytes from a total that claims to
// be complete.
func walkIDBothDirBuffer(buf []byte, visit func(idBothDirEntry) error) error {
	if len(buf) == 0 {
		return nil
	}
	for offset := 0; ; {
		remaining := len(buf) - offset
		if remaining < idBothDirNameOffset {
			return &malformedDirBufferError{
				reason: fmt.Sprintf("record at %d holds %d bytes, the fixed part needs %d", offset, remaining, idBothDirNameOffset),
			}
		}
		record := (*idBothDirRecord)(unsafe.Pointer(&buf[offset]))
		nameBytes := int(record.FileNameLength)
		if nameBytes <= 0 || nameBytes%2 != 0 {
			return &malformedDirBufferError{
				reason: fmt.Sprintf("record at %d reports an invalid name length %d", offset, nameBytes),
			}
		}
		if remaining < idBothDirNameOffset+nameBytes {
			return &malformedDirBufferError{
				reason: fmt.Sprintf("record at %d reports a %d-byte name but only %d bytes remain", offset, nameBytes, remaining-idBothDirNameOffset),
			}
		}
		name := decodeDirName(unsafe.Slice(&record.FileName[0], nameBytes/2))
		if name != "." && name != ".." {
			if err := visit(decodeIDBothDirRecord(record, name)); err != nil {
				return err
			}
		}

		next := int(record.NextEntryOffset)
		if next == 0 {
			return nil
		}
		minNext := (idBothDirNameOffset + nameBytes + 7) &^ 7
		if next < minNext || next%8 != 0 || next > remaining-idBothDirNameOffset {
			return &malformedDirBufferError{
				reason: fmt.Sprintf("record at %d points to invalid record boundary %d within %d bytes", offset, next, remaining),
			}
		}
		offset += next
	}
}

// decodeIDBothDirRecord copies the fields this package uses into a value that
// does not alias the record buffer.
func decodeIDBothDirRecord(record *idBothDirRecord, name string) idBothDirEntry {
	return idBothDirEntry{
		Name:           name,
		FileID:         record.FileID,
		Size:           int64(record.EndOfFile),
		AllocationSize: int64(record.AllocationSize),
		Attributes:     record.FileAttributes,
		// EaSize carries the reparse tag when the entry is a reparse point.
		ReparseTag:     record.EaSize,
		CreationTime:   record.CreationTime,
		LastAccessTime: record.LastAccessTime,
		LastWriteTime:  record.LastWriteTime,
	}
}

// filetimeToTime converts a FILETIME to Unix time. A zero or pre-1970 value
// reports the zero time, which callers already treat as "not recorded".
func filetimeToTime(stamp fileTimestamp) time.Time {
	ticks := int64(stamp.HighDateTime)<<32 | int64(stamp.LowDateTime)
	if ticks < filetimeUnixEpoch {
		return time.Time{}
	}
	ticks -= filetimeUnixEpoch
	return time.Unix(ticks/filetimeTicksPerSecond, (ticks%filetimeTicksPerSecond)*100).UTC()
}
