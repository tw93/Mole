//go:build darwin

package main

import _ "embed"

// iconData is a 16x16 monochrome PNG embedded at compile time.
// macOS will auto-tint this template icon for light/dark mode.
//
//go:embed icon.png
var iconData []byte
