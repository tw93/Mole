package main

import (
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestCommandLineQuotesEveryArgument(t *testing.T) {
	got := commandLine(`C:\Program Files\Mole\mole.ps1`, []string{"clean", "--dry-run", "it's", "$env:USERPROFILE", "a b"})
	want := `& 'C:\Program Files\Mole\mole.ps1' 'clean' '--dry-run' 'it''s' '$env:USERPROFILE' 'a b'; exit $LASTEXITCODE`
	if got != want {
		t.Fatalf("commandLine:\n got %s\nwant %s", got, want)
	}
}

func TestCommandLineDoublesTypographicQuotes(t *testing.T) {
	// PowerShell ends a single-quoted string at U+2018 to U+201B as well as at ', so each is doubled.
	got := commandLine("C:\\Users\\John O\u2019Brien\\scoop\\apps\\mole\\current\\mole.ps1", []string{"\u2018a\u201ab\u201b"})
	want := "& 'C:\\Users\\John O\u2019\u2019Brien\\scoop\\apps\\mole\\current\\mole.ps1' '\u2018\u2018a\u201a\u201ab\u201b\u201b'; exit $LASTEXITCODE"
	if got != want {
		t.Fatalf("commandLine:\n got %s\nwant %s", got, want)
	}
}

func TestCommandLineWithoutArgumentsOpensTheMenu(t *testing.T) {
	got := commandLine(`C:\Mole\mole.ps1`, nil)
	want := `& 'C:\Mole\mole.ps1'; exit $LASTEXITCODE`
	if got != want {
		t.Fatalf("commandLine:\n got %s\nwant %s", got, want)
	}
}

func TestPowerShellCandidatesTryWindowsPowerShellFirst(t *testing.T) {
	t.Setenv("SystemRoot", `C:\TestWindows`)
	got := powerShellCandidates()
	want := filepath.Join(`C:\TestWindows`, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	if len(got) == 0 || got[0] != want {
		t.Fatalf("powerShellCandidates first entry: got %v, want %s", got, want)
	}
}

func TestRunPowerShellFallsBackWhenTheFirstHostCannotStart(t *testing.T) {
	t.Setenv("MOLE_TEST_POWERSHELL_EXIT", "7")
	missing := filepath.Join(t.TempDir(), "powershell.exe")

	code, err := runPowerShell([]string{missing, os.Args[0]}, []string{"-test.run=^TestPowerShellHelperProcess$"}, nil, io.Discard, io.Discard)
	if err != nil {
		t.Fatalf("runPowerShell returned %v", err)
	}
	if code != 7 {
		t.Fatalf("runPowerShell exit code: got %d, want 7", code)
	}
}

func TestRunPowerShellDoesNotRetryAfterTheHostStarts(t *testing.T) {
	t.Setenv("MOLE_TEST_POWERSHELL_EXIT", "7")
	missing := filepath.Join(t.TempDir(), "pwsh.exe")

	code, err := runPowerShell([]string{os.Args[0], missing}, []string{"-test.run=^TestPowerShellHelperProcess$"}, nil, io.Discard, io.Discard)
	if err != nil {
		t.Fatalf("runPowerShell returned %v", err)
	}
	if code != 7 {
		t.Fatalf("runPowerShell exit code: got %d, want 7", code)
	}
}

func TestRunPowerShellReportsEveryHostThatCouldNotStart(t *testing.T) {
	dir := t.TempDir()
	first := filepath.Join(dir, "powershell.exe")
	second := filepath.Join(dir, "pwsh.exe")

	code, err := runPowerShell([]string{first, second}, nil, nil, io.Discard, io.Discard)
	if err == nil {
		t.Fatal("runPowerShell succeeded with two missing hosts")
	}
	if code != 1 {
		t.Fatalf("runPowerShell exit code: got %d, want 1", code)
	}
	for _, path := range []string{first, second} {
		if !strings.Contains(err.Error(), path) {
			t.Fatalf("error %q does not mention %s", err, path)
		}
	}
}

func TestPowerShellHelperProcess(t *testing.T) {
	value := os.Getenv("MOLE_TEST_POWERSHELL_EXIT")
	if value == "" {
		return
	}
	code, err := strconv.Atoi(value)
	if err != nil {
		os.Exit(2)
	}
	os.Exit(code)
}
