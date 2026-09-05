//go:build darwin

package main

import (
	"bytes"
	"flag"
	"strings"
	"testing"
)

// resetFlags restores the package-level flag set between cases. parseArgs calls
// Init on flag.CommandLine, so a case that runs after a failed parse would
// otherwise inherit the previous run's error handling.
func resetFlags(t *testing.T) {
	t.Helper()
	saved := *jsonMode
	t.Cleanup(func() {
		flag.CommandLine.Init("mo analyze", flag.ExitOnError)
		*jsonMode = saved
	})
}

func TestParseArgsHelpGoesToStdout(t *testing.T) {
	for _, arg := range []string{"-h", "--help", "-help"} {
		t.Run(arg, func(t *testing.T) {
			resetFlags(t)
			var stdout, stderr bytes.Buffer

			code, keepGoing := parseArgs([]string{arg}, &stdout, &stderr)

			if keepGoing {
				t.Fatalf("parseArgs(%q) kept going, want early exit", arg)
			}
			if code != 0 {
				t.Errorf("exit code = %d, want 0", code)
			}
			if stderr.Len() != 0 {
				t.Errorf("stderr = %q, want empty: help is data, not an error", stderr.String())
			}
			if !strings.HasPrefix(stdout.String(), "Usage: mo analyze") {
				t.Errorf("stdout = %q, want it to start with the mo analyze usage line", stdout.String())
			}
		})
	}
}

// The flag package names os.Args[0], which for a bundled binary is a path the
// user never typed. Guard against a regression that reintroduces it.
func TestParseArgsHelpNeverNamesTheBundledBinary(t *testing.T) {
	resetFlags(t)
	var stdout, stderr bytes.Buffer

	parseArgs([]string{"--help"}, &stdout, &stderr)

	if strings.Contains(stdout.String(), "Usage of ") {
		t.Errorf("stdout = %q, want no flag-package 'Usage of <path>' line", stdout.String())
	}
	if strings.Contains(stdout.String(), "analyze-go") {
		t.Errorf("stdout = %q, want no bundled binary name", stdout.String())
	}
}

func TestParseArgsUnknownFlagExitsOne(t *testing.T) {
	resetFlags(t)
	var stdout, stderr bytes.Buffer

	code, keepGoing := parseArgs([]string{"--bogus"}, &stdout, &stderr)

	if keepGoing {
		t.Fatal("parseArgs kept going on an unknown flag, want early exit")
	}
	// Every bash subcommand exits 1 on a bad option; the flag package's default
	// is 2, which made mo analyze the odd one out.
	if code != 1 {
		t.Errorf("exit code = %d, want 1", code)
	}
	if stdout.Len() != 0 {
		t.Errorf("stdout = %q, want empty: errors go to stderr", stdout.String())
	}
	if !strings.Contains(stderr.String(), "not defined") {
		t.Errorf("stderr = %q, want it to name the offending flag", stderr.String())
	}
	if !strings.Contains(stderr.String(), "mo analyze --help") {
		t.Errorf("stderr = %q, want it to point at mo analyze --help", stderr.String())
	}
}

func TestParseArgsAcceptsKnownFlagsAndPath(t *testing.T) {
	resetFlags(t)
	var stdout, stderr bytes.Buffer

	code, keepGoing := parseArgs([]string{"--json", "/Volumes"}, &stdout, &stderr)

	if !keepGoing || code != 0 {
		t.Fatalf("parseArgs = (%d, %v), want (0, true)", code, keepGoing)
	}
	if !*jsonMode {
		t.Error("--json did not set jsonMode")
	}
	if got := flag.Args(); len(got) != 1 || got[0] != "/Volumes" {
		t.Errorf("positional args = %v, want [/Volumes]", got)
	}
	if stdout.Len() != 0 || stderr.Len() != 0 {
		t.Errorf("a valid invocation printed stdout=%q stderr=%q, want both empty", stdout.String(), stderr.String())
	}
}
