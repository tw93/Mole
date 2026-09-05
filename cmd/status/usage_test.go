package main

import (
	"bytes"
	"flag"
	"strings"
	"testing"
	"time"
)

// resetFlags restores the package-level flag set and flag values between cases.
// parseArgs calls Init on flag.CommandLine, so a case that runs after a failed
// parse would otherwise inherit the previous run's error handling.
func resetFlags(t *testing.T) {
	t.Helper()
	savedJSON, savedWatch := *jsonOutput, *watchMode
	savedThreshold, savedWindow := *procCPUThreshold, *procCPUWindow
	savedInterval := *watchInterval
	t.Cleanup(func() {
		flag.CommandLine.Init("mo status", flag.ExitOnError)
		*jsonOutput, *watchMode = savedJSON, savedWatch
		*procCPUThreshold, *procCPUWindow = savedThreshold, savedWindow
		*watchInterval = savedInterval
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
			if !strings.HasPrefix(stdout.String(), "Usage: mo status") {
				t.Errorf("stdout = %q, want it to start with the mo status usage line", stdout.String())
			}
		})
	}
}

// Help that omits a flag is help that goes stale. Every declared flag must show up.
func TestParseArgsHelpListsEveryFlag(t *testing.T) {
	resetFlags(t)
	var stdout, stderr bytes.Buffer
	parseArgs([]string{"--help"}, &stdout, &stderr)

	flag.CommandLine.VisitAll(func(f *flag.Flag) {
		// The test binary registers its own -test.* flags on the same set.
		if strings.HasPrefix(f.Name, "test.") {
			return
		}
		if !strings.Contains(stdout.String(), "--"+f.Name) {
			t.Errorf("usage text does not document --%s", f.Name)
		}
	})
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
	if strings.Contains(stdout.String(), "status-go") {
		t.Errorf("stdout = %q, want no bundled binary name", stdout.String())
	}
}

func TestParseArgsRejectsBadInvocations(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"unknown flag", []string{"--bogus"}, "not defined"},
		{"negative threshold", []string{"--proc-cpu-threshold=-1"}, "--proc-cpu-threshold"},
		{"zero window", []string{"--proc-cpu-window=0s"}, "--proc-cpu-window"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resetFlags(t)
			var stdout, stderr bytes.Buffer

			code, keepGoing := parseArgs(tc.args, &stdout, &stderr)

			if keepGoing {
				t.Fatalf("parseArgs(%v) kept going, want early exit", tc.args)
			}
			// Every bash subcommand exits 1 on a bad option; the flag package's
			// default is 2, which made mo status the odd one out.
			if code != 1 {
				t.Errorf("exit code = %d, want 1", code)
			}
			if stdout.Len() != 0 {
				t.Errorf("stdout = %q, want empty: errors go to stderr", stdout.String())
			}
			if !strings.Contains(stderr.String(), tc.want) {
				t.Errorf("stderr = %q, want it to mention %q", stderr.String(), tc.want)
			}
			if !strings.Contains(stderr.String(), "mo status --help") {
				t.Errorf("stderr = %q, want it to point at mo status --help", stderr.String())
			}
		})
	}
}

func TestParseArgsAcceptsKnownFlags(t *testing.T) {
	resetFlags(t)
	var stdout, stderr bytes.Buffer

	code, keepGoing := parseArgs([]string{"--watch", "--interval", "2s", "--proc-cpu-window", "1m"}, &stdout, &stderr)

	if !keepGoing || code != 0 {
		t.Fatalf("parseArgs = (%d, %v), want (0, true)", code, keepGoing)
	}
	if !*watchMode || *watchInterval != "2s" || *procCPUWindow != time.Minute {
		t.Errorf("flags = watch:%v interval:%q window:%v, want true, \"2s\", 1m", *watchMode, *watchInterval, *procCPUWindow)
	}
	if stdout.Len() != 0 || stderr.Len() != 0 {
		t.Errorf("a valid invocation printed stdout=%q stderr=%q, want both empty", stdout.String(), stderr.String())
	}
}
