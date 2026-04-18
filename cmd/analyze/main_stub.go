//go:build !darwin

package main

import (
	"fmt"
	"os"
)

func main() {
	msg := "analyze is only supported on macOS"
	if os.Getenv("MOLE_IS_TURKISH_SYSTEM") == "true" {
		msg = "analyze yalnızca macOS üzerinde desteklenir"
	}
	fmt.Fprintln(os.Stderr, msg)
	os.Exit(1)
}
