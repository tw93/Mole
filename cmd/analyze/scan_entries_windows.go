//go:build windows

package main

import (
	"errors"
	"io/fs"
	"os"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
)

type scanDirEntry struct {
	record   *idBothDirEntry
	fallback fs.DirEntry
}

const dedupReparseTag = 0x80000013

// readIdentityRecords is readDirIdentityRecords; tests replace it to reach the
// fallback branches without a misbehaving file system driver.
var readIdentityRecords = readDirIdentityRecords

func readScanEntries(path string) ([]scanDirEntry, error) {
	records, err := readIdentityRecords(path)
	// A volume without file IDs, or a third-party driver (WinFsp, Dokan) that
	// claims them but writes records the walker cannot decode, still lists
	// through os.ReadDir; only that directory loses hard-link deduplication.
	var malformed *malformedDirBufferError
	if errors.Is(err, errIdentitiesUnavailable) || errors.As(err, &malformed) {
		entries, fallbackErr := os.ReadDir(path)
		if fallbackErr != nil {
			return nil, fallbackErr
		}
		result := make([]scanDirEntry, len(entries))
		for index, entry := range entries {
			result[index].fallback = entry
		}
		return result, nil
	}
	if err != nil {
		return nil, err
	}
	result := make([]scanDirEntry, len(records))
	for index := range records {
		result[index].record = &records[index]
	}
	return result, nil
}

func (e scanDirEntry) Name() string {
	if e.fallback != nil {
		return e.fallback.Name()
	}
	return e.record.Name
}

func (e scanDirEntry) IsDir() bool { return e.Type().IsDir() }

func (e scanDirEntry) Type() fs.FileMode {
	if e.fallback != nil {
		return e.fallback.Type()
	}
	return recordMode(*e.record).Type()
}

func (e scanDirEntry) Info() (fs.FileInfo, error) {
	if e.fallback != nil {
		return e.fallback.Info()
	}
	return scanFileInfo{record: e.record}, nil
}

type scanFileInfo struct{ record *idBothDirEntry }

func (i scanFileInfo) Name() string       { return i.record.Name }
func (i scanFileInfo) Size() int64        { return i.record.Size }
func (i scanFileInfo) Mode() fs.FileMode  { return recordMode(*i.record) }
func (i scanFileInfo) ModTime() time.Time { return filetimeToTime(i.record.LastWriteTime) }
func (i scanFileInfo) IsDir() bool        { return i.Mode().IsDir() }

func (i scanFileInfo) Sys() any {
	return &syscall.Win32FileAttributeData{
		FileAttributes: i.record.Attributes,
		CreationTime:   syscall.Filetime{LowDateTime: i.record.CreationTime.LowDateTime, HighDateTime: i.record.CreationTime.HighDateTime},
		LastAccessTime: syscall.Filetime{LowDateTime: i.record.LastAccessTime.LowDateTime, HighDateTime: i.record.LastAccessTime.HighDateTime},
		LastWriteTime:  syscall.Filetime{LowDateTime: i.record.LastWriteTime.LowDateTime, HighDateTime: i.record.LastWriteTime.HighDateTime},
		FileSizeHigh:   uint32(uint64(i.record.Size) >> 32),
		FileSizeLow:    uint32(i.record.Size),
	}
}

func recordMode(record idBothDirEntry) fs.FileMode {
	mode := fs.FileMode(0o666)
	if record.Attributes&windows.FILE_ATTRIBUTE_READONLY != 0 {
		mode = 0o444
	}
	nameSurrogate := record.Attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 && record.ReparseTag&0x20000000 != 0
	if record.Attributes&windows.FILE_ATTRIBUTE_DIRECTORY != 0 && !nameSurrogate {
		mode |= fs.ModeDir | 0o111
	}
	if record.Attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		switch record.ReparseTag {
		case windows.IO_REPARSE_TAG_SYMLINK:
			mode |= fs.ModeSymlink
		case dedupReparseTag:
		default:
			mode |= fs.ModeIrregular
		}
	}
	return mode
}
