// Package main provides the mo speedtest command for network speed diagnostics.
// It measures latency, download speed, and upload speed using lightweight
// HTTP-based tests against Cloudflare's speed test infrastructure, avoiding
// any proprietary API keys or heavyweight CLI dependencies.
package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	jsonMode := flag.Bool("json", false, "output results as JSON")
	flag.Parse()

	runner := NewRunner()
	if *jsonMode || isNonInteractive(os.Stdout) {
		runJSONMode(runner)
	} else {
		runTUIMode(runner)
	}
}

func isNonInteractive(f *os.File) bool {
	if f == nil {
		return false
	}
	info, err := f.Stat()
	if err != nil {
		return false
	}
	return (info.Mode() & os.ModeCharDevice) == 0
}

func runJSONMode(r *Runner) {
	result, err := r.Run()
	if err != nil {
		fmt.Fprintf(os.Stderr, "speedtest error: %v\n", err)
		os.Exit(1)
	}
	fmt.Println(result.JSON())
}

func runTUIMode(r *Runner) {
	p := newTUIProgram(r)
	if err := p.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "speedtest error: %v\n", err)
		os.Exit(1)
	}
}
