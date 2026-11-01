//go:build linux

// Command trash moves paths into the freedesktop.org Trash through
// internal/xdgtrash. The bash commands (clean, uninstall) call it so every
// user-file removal in Mole CLI (Linux) goes through one implementation.
//
// Output, one line per path, tab separated:
//
//	ok	<source>	<trash file>
//	error	<source>	<reason>      (on stderr)
//
// Exit status is 1 when any path failed, 2 on usage errors.
package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/tw93/mole/internal/xdgtrash"
)

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "--" {
		args = args[1:]
	}
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: trash-go [--] <path>...")
		os.Exit(2)
	}
	env, err := xdgtrash.DefaultEnv()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error\t-\t%s\n", err)
		os.Exit(1)
	}
	failed := false
	for _, p := range args {
		res, err := env.Move(p)
		if err != nil {
			failed = true
			fmt.Fprintf(os.Stderr, "error\t%s\t%s\n", p, oneLine(err.Error()))
			continue
		}
		fmt.Printf("ok\t%s\t%s\n", res.Source, res.TrashFile)
	}
	if failed {
		os.Exit(1)
	}
}

func oneLine(s string) string {
	return strings.NewReplacer("\n", " ", "\t", " ").Replace(s)
}
