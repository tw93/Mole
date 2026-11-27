//go:build !darwin || !arm64

package main

func readSMCDesktopPower() float64 { return 0 }
