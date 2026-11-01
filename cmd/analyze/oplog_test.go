package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestMain keeps every test in this package off the user's real Mole logs:
// the delete commands now append to $XDG_STATE_HOME/mole, and a test that
// forgets to repoint HOME must not land rows in the real operations.log.
func TestMain(m *testing.M) {
	scratch, err := os.MkdirTemp("", "mole-analyze-logs-")
	if err != nil {
		panic(err)
	}
	os.Setenv("MO_NO_OPLOG", "1")
	os.Setenv("MOLE_DELETE_LOG", filepath.Join(scratch, "deletions.log"))
	code := m.Run()
	os.RemoveAll(scratch)
	os.Exit(code)
}

// The shapes Mole-Diagnose.command keeps (mole-mac site/downloads), so a
// drift in the row format fails here rather than in a support bundle.
var (
	cliOperationRow = regexp.MustCompile(`^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] \[([a-z][a-z0-9._-]*(?: run=[0-9-]+)?)\] ([A-Z][A-Z_]*) (.+)$`)
	cliSessionRow   = regexp.MustCompile(`^# =+ [a-z][a-z0-9._-]*(?: run=[0-9-]+)? session (?:started|ended) at \d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:, \d+ items, \d+(?:\.\d+)?[KMGT]?B)? =+$`)
)

func enableAnalyzeLogs(t *testing.T) (string, string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_STATE_HOME", "")
	t.Setenv("MO_NO_OPLOG", "")
	t.Setenv("MOLE_DELETE_LOG", "")
	logDir := filepath.Join(home, ".local", "state", "mole")
	return filepath.Join(logDir, "operations.log"), filepath.Join(logDir, "deletions.log")
}

func readLogLines(t *testing.T, path string) []string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
}

func TestAnalyzeDeleteLogsARefusedPathAsAFailedRow(t *testing.T) {
	opLog, delLog := enableAnalyzeLogs(t)
	home := os.Getenv("HOME")

	// HOME itself exists and is refused before any Trash move.
	var counter int64
	msg := deleteMultiplePathsCmd([]string{home}, &counter, newDeleteAudit(map[string]int64{home: 2048}))()
	progress := msg.(deleteProgressMsg)
	if progress.err == nil {
		t.Fatalf("expected HOME to be refused")
	}
	if _, err := os.Stat(home); err != nil {
		t.Fatalf("HOME must survive: %v", err)
	}

	lines := readLogLines(t, opLog)
	if len(lines) != 4 || lines[0] != "" {
		t.Fatalf("expected blank line, start, row, end; got %q", lines)
	}
	if !cliSessionRow.MatchString(lines[1]) || !strings.Contains(lines[1], " session started at ") {
		t.Fatalf("start marker shape: %q", lines[1])
	}
	match := cliOperationRow.FindStringSubmatch(lines[2])
	if match == nil {
		t.Fatalf("row shape: %q", lines[2])
	}
	if !strings.HasPrefix(match[2], "analyze run=") || match[3] != "FAILED" || match[4] != home+" (protected)" {
		t.Fatalf("unexpected row: %q", lines[2])
	}
	if !cliSessionRow.MatchString(lines[3]) || !strings.HasSuffix(lines[3], ", 0 items, 0B ==========") {
		t.Fatalf("end marker shape: %q", lines[3])
	}
	if !strings.Contains(lines[1], match[2]+" session") || !strings.Contains(lines[3], match[2]+" session") {
		t.Fatalf("markers and row must share one run id: %q", lines)
	}

	rows := readLogLines(t, delLog)
	fields := strings.Split(rows[0], "\t")
	if len(rows) != 1 || len(fields) != 5 || fields[1] != "trash" || fields[2] != "2" || fields[3] != "trash-failed" || fields[4] != home {
		t.Fatalf("unexpected deletions row: %q", rows)
	}
	if progress.logWarning != "" {
		t.Fatalf("no warning expected for a writable log: %q", progress.logWarning)
	}
}

func TestAnalyzeAuditRecordsTrashedPathWithItsSize(t *testing.T) {
	opLog, delLog := enableAnalyzeLogs(t)
	target := "/Users/someone/Downloads/model\nweights"
	audit := newDeleteAudit(map[string]int64{target: 3_400_000_000})
	audit.begin()
	audit.record(target, nil)
	audit.record("/gone", os.ErrNotExist)
	audit.end()

	lines := readLogLines(t, opLog)
	if len(lines) != 4 {
		t.Fatalf("a path already gone must not be logged: %q", lines)
	}
	match := cliOperationRow.FindStringSubmatch(lines[2])
	if match == nil || match[3] != "TRASHED" || match[4] != `/Users/someone/Downloads/model\nweights (3.40GB)` {
		t.Fatalf("unexpected row: %q", lines[2])
	}
	if !strings.HasSuffix(lines[3], ", 1 items, 3.40GB ==========") || !cliSessionRow.MatchString(lines[3]) {
		t.Fatalf("end marker: %q", lines[3])
	}
	rows := readLogLines(t, delLog)
	if len(rows) != 1 || !strings.HasSuffix(rows[0], "\ttrash\t3320313\tok\t/Users/someone/Downloads/model\\nweights") {
		t.Fatalf("unexpected deletions row: %q", rows)
	}
}

func TestAnalyzeAuditHonorsMoNoOplog(t *testing.T) {
	opLog, delLog := enableAnalyzeLogs(t)
	t.Setenv("MO_NO_OPLOG", "1")
	audit := newDeleteAudit(nil)
	audit.begin()
	audit.record("/home/someone/file", nil)
	audit.end()
	if _, err := os.Stat(opLog); !os.IsNotExist(err) {
		t.Fatalf("operations.log must stay unwritten with MO_NO_OPLOG=1: %v", err)
	}
	// The deletions log is the Trash audit trail and is written regardless,
	// as on the shell side.
	if rows := readLogLines(t, delLog); len(rows) != 1 {
		t.Fatalf("expected one deletions row, got %q", rows)
	}
}

func TestAnalyzeAuditReportsAnUnwritableLog(t *testing.T) {
	enableAnalyzeLogs(t)
	home := os.Getenv("HOME")
	if err := os.WriteFile(filepath.Join(home, ".local"), []byte("not a folder"), 0o644); err != nil {
		t.Fatal(err)
	}
	audit := newDeleteAudit(nil)
	audit.begin()
	audit.record("/home/someone/file", nil)
	audit.end()
	if audit.warning() == "" {
		t.Fatalf("a failed log write must surface a warning")
	}
}

func TestOperationsLogPathFollowsXDGStateHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_STATE_HOME", "")
	if got, ok := operationsLogPath(); !ok || got != filepath.Join(home, ".local", "state", "mole", "operations.log") {
		t.Fatalf("default operations log = %q, %v", got, ok)
	}
	state := t.TempDir()
	t.Setenv("XDG_STATE_HOME", state)
	if got, ok := operationsLogPath(); !ok || got != filepath.Join(state, "mole", "operations.log") {
		t.Fatalf("XDG operations log = %q, %v", got, ok)
	}
	t.Setenv("XDG_STATE_HOME", "relative/state")
	if got, _ := operationsLogPath(); got != filepath.Join(home, ".local", "state", "mole", "operations.log") {
		t.Fatalf("relative XDG_STATE_HOME must be ignored, got %q", got)
	}
}

func TestLogSizeTextMatchesShellBytesToHuman(t *testing.T) {
	cases := map[int64]string{0: "0B", 999: "999B", 1000: "1KB", 1499: "1KB", 1_500_000: "1.5MB", 2_345_000_000: "2.35GB"}
	for in, want := range cases {
		if got := logSizeText(in); got != want {
			t.Errorf("logSizeText(%d) = %q, want %q", in, got, want)
		}
	}
}

func TestEscapeLogValueMatchesShellEscaping(t *testing.T) {
	got := escapeLogValue("a\tb\rc\x01d\x7fe\\n")
	want := `a\tb\rc\x01d\x7fe\n`
	if got != want {
		t.Fatalf("escapeLogValue = %q, want %q", got, want)
	}
}
