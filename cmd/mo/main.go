// Command mo starts mole.ps1 from the same folder with Windows PowerShell.
//
// Package managers that can only expose an executable (winget portable
// installs) put this on PATH as `mo`. It passes every argument through as a
// literal PowerShell string, the same call shape as the mo.cmd launcher that
// install.ps1 writes, and returns the script's exit code.
package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	script, err := scriptPath()
	if err != nil {
		fmt.Fprintf(os.Stderr, "mo: %v\n", err)
		return 1
	}

	// The console sends Ctrl+C to PowerShell as well; let it decide.
	signal.Ignore(os.Interrupt)

	psArgs := []string{"-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", commandLine(script, args)}
	code, err := runPowerShell(powerShellCandidates(), psArgs, os.Stdin, os.Stdout, os.Stderr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mo: %v\n", err)
		return 1
	}
	return code
}

// scriptPath resolves mole.ps1 beside the real executable; winget runs this
// through a symlink in its Links folder.
func scriptPath() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	script := filepath.Join(filepath.Dir(exe), "mole.ps1")
	if _, err := os.Stat(script); err != nil {
		return "", fmt.Errorf("mole.ps1 not found next to %s", exe)
	}
	return script, nil
}

// powerShellCandidates lists the PowerShell hosts to try, in order. Windows
// PowerShell is the supported target; pwsh is a fallback for machines where
// policy blocks powershell.exe (AppLocker, SRP).
func powerShellCandidates() []string {
	candidates := []string{windowsPowerShellPath()}
	if pwsh, err := exec.LookPath("pwsh.exe"); err == nil {
		candidates = append(candidates, pwsh)
	}
	return candidates
}

// windowsPowerShellPath is the absolute Windows PowerShell path, so a
// powershell.exe earlier on PATH is never picked up instead.
func windowsPowerShellPath() string {
	root := os.Getenv("SystemRoot")
	if root == "" {
		root = `C:\Windows`
	}
	return filepath.Join(root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
}

// runPowerShell starts the first host that can be started. A host failure
// after its process starts is returned as an exit code and never retried on
// another host, so a command cannot run twice.
func runPowerShell(candidates []string, args []string, stdin io.Reader, stdout, stderr io.Writer) (int, error) {
	var failures []string
	for _, path := range candidates {
		cmd := exec.Command(path, args...)
		cmd.Stdin, cmd.Stdout, cmd.Stderr = stdin, stdout, stderr
		err := cmd.Run()
		if err == nil {
			return 0, nil
		}
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return exitErr.ExitCode(), nil
		}
		failures = append(failures, err.Error())
	}
	return 1, fmt.Errorf("could not start PowerShell:\n  %s", strings.Join(failures, "\n  "))
}

// commandLine builds `& 'script' 'arg' ...; exit $LASTEXITCODE` with every
// value single-quoted, so PowerShell never expands or splits an argument.
func commandLine(script string, args []string) string {
	parts := make([]string, 0, len(args)+2)
	parts = append(parts, "&", quote(script))
	for _, arg := range args {
		parts = append(parts, quote(arg))
	}
	return strings.Join(parts, " ") + "; exit $LASTEXITCODE"
}

// singleQuotes are the characters PowerShell accepts as a single quote: the
// ASCII one and the typographic U+2018 to U+201B. Inside a single-quoted
// literal any of them ends the string unless it is doubled, so a profile path
// such as C:\Users\John O’Brien broke every command (tw93/Mole#2021).
var singleQuotes = strings.NewReplacer(
	"'", "''",
	"\u2018", "\u2018\u2018",
	"\u2019", "\u2019\u2019",
	"\u201a", "\u201a\u201a",
	"\u201b", "\u201b\u201b",
)

func quote(value string) string {
	return "'" + singleQuotes.Replace(value) + "'"
}
