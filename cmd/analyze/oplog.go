package main

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// deleteAudit writes one analyze delete batch into the logs the shell side
// keeps: operations.log rows in the shared format Mole Mac and the support
// diagnostic read ('[local time] [analyze run=<id>] ACTION path (detail)',
// framed by session markers), plus one deletions.log TSV row per item.
// Without it a Trash move made from analyze left no trace anywhere.
type deleteAudit struct {
	runID      string
	sizes      map[string]int64
	items      int
	bytes      int64
	writeError error
}

const analyzeLogCommand = "analyze"

func newDeleteAudit(sizes map[string]int64) *deleteAudit {
	now := time.Now()
	// Same opaque shape as the shell's run id: timestamp digits, pid, and two
	// numbers in $RANDOM's range.
	var noise [4]byte
	_, _ = rand.Read(noise[:])
	runID := fmt.Sprintf("%s-%d-%d-%d", now.Format("20060102150405"), os.Getpid(),
		binary.BigEndian.Uint16(noise[:2])&0x7fff, binary.BigEndian.Uint16(noise[2:])&0x7fff)
	return &deleteAudit{runID: runID, sizes: sizes}
}

func operationsLogEnabled() bool {
	return os.Getenv("MO_NO_OPLOG") != "1"
}

func moleLogDir() (string, bool) {
	state := os.Getenv("XDG_STATE_HOME")
	if !filepath.IsAbs(state) {
		home := os.Getenv("HOME")
		if home == "" {
			return "", false
		}
		state = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(state, "mole"), true
}

func operationsLogPath() (string, bool) {
	dir, ok := moleLogDir()
	if !ok {
		return "", false
	}
	return filepath.Join(dir, "operations.log"), true
}

func deletionsLogPath() (string, bool) {
	if custom := os.Getenv("MOLE_DELETE_LOG"); custom != "" {
		return custom, true
	}
	dir, ok := moleLogDir()
	if !ok {
		return "", false
	}
	return filepath.Join(dir, "deletions.log"), true
}

// escapeLogValue mirrors _mole_escape_log_value in lib/core/base.sh: control
// bytes are written as \n, \r, \t or \xHH so a name cannot forge a record,
// and backslashes stay literal so history shows the name as it is on disk.
func escapeLogValue(value string) string {
	var b strings.Builder
	for i := 0; i < len(value); i++ {
		c := value[i]
		switch {
		case c == '\n':
			b.WriteString(`\n`)
		case c == '\r':
			b.WriteString(`\r`)
		case c == '\t':
			b.WriteString(`\t`)
		case c < 0x20 || c == 0x7f:
			fmt.Fprintf(&b, `\x%02x`, c)
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}

// logSizeText mirrors bytes_to_human in lib/core/base.sh, the size shape the
// support diagnostic keeps as a detail.
func logSizeText(bytes int64) string {
	switch {
	case bytes >= 1_000_000_000:
		scaled := (bytes*100 + 500_000_000) / 1_000_000_000
		return fmt.Sprintf("%d.%02dGB", scaled/100, scaled%100)
	case bytes >= 1_000_000:
		scaled := (bytes*10 + 500_000) / 1_000_000
		return fmt.Sprintf("%d.%01dMB", scaled/10, scaled%10)
	case bytes >= 1_000:
		return fmt.Sprintf("%dKB", (bytes+500)/1000)
	default:
		return fmt.Sprintf("%dB", max(bytes, 0))
	}
}

func appendLogLines(path string, lines ...string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	_, writeErr := file.WriteString(strings.Join(lines, "\n") + "\n")
	closeErr := file.Close()
	if writeErr != nil {
		return writeErr
	}
	return closeErr
}

func (a *deleteAudit) noteError(err error) {
	if err != nil && a.writeError == nil {
		a.writeError = err
	}
}

func (a *deleteAudit) commandField() string {
	return analyzeLogCommand + " run=" + a.runID
}

func (a *deleteAudit) appendOperation(lines ...string) {
	if !operationsLogEnabled() {
		return
	}
	path, ok := operationsLogPath()
	if !ok {
		return
	}
	a.noteError(appendLogLines(path, lines...))
}

func (a *deleteAudit) begin() {
	if a == nil {
		return
	}
	stamp := time.Now().Format("2006-01-02 15:04:05")
	a.appendOperation("", fmt.Sprintf("# ========== %s session started at %s ==========", a.commandField(), stamp))
}

// failureReason maps a Trash error to a fixed reason string; the support
// diagnostic keeps only fixed strings, and an error text can carry a path.
func failureReason(err error) string {
	text := err.Error()
	switch {
	case strings.Contains(text, "protected path"):
		return "protected"
	case strings.Contains(text, "timeout"):
		return "removal timed out"
	case errors.Is(err, os.ErrPermission):
		return "permission denied"
	default:
		return "trash-failed"
	}
}

// record logs one selected path. A path already gone before the move is
// not logged: analyze did nothing to it.
func (a *deleteAudit) record(path string, err error) {
	if a == nil || (err != nil && os.IsNotExist(err)) {
		return
	}
	size := a.sizes[path]
	stamp := time.Now().Format("2006-01-02 15:04:05")
	var line, status string
	if err == nil {
		line = fmt.Sprintf("[%s] [%s] TRASHED %s", stamp, a.commandField(), escapeLogValue(path))
		// Every row ends in one "(detail)", "-" when there is none, so
		// mo history can split it from a path that holds parentheses.
		detail := "-"
		if size > 0 {
			detail = logSizeText(size)
		}
		line += " (" + detail + ")"
		status = "ok"
		a.items++
		a.bytes += max(size, 0)
	} else {
		line = fmt.Sprintf("[%s] [%s] FAILED %s (%s)", stamp, a.commandField(), escapeLogValue(path), failureReason(err))
		status = "trash-failed"
	}
	a.appendOperation(line)

	if logPath, ok := deletionsLogPath(); ok {
		sizeKB := (max(size, 0) + 1023) / 1024
		row := strings.Join([]string{
			time.Now().Format("2006-01-02T15:04:05-0700"),
			"trash",
			fmt.Sprintf("%d", sizeKB),
			status,
			escapeLogValue(path),
		}, "\t")
		a.noteError(appendLogLines(logPath, row))
	}
}

func (a *deleteAudit) end() {
	if a == nil {
		return
	}
	stamp := time.Now().Format("2006-01-02 15:04:05")
	a.appendOperation(fmt.Sprintf("# ========== %s session ended at %s, %d items, %s ==========",
		a.commandField(), stamp, a.items, logSizeText(a.bytes)))
}

// warning is the one status note a failed log write leaves, so the trail is
// never missing without the user being told.
func (a *deleteAudit) warning() string {
	if a == nil || a.writeError == nil {
		return ""
	}
	return "audit log unavailable"
}
