//go:build darwin

package main

const (
	scoreStorage     = 20
	scorePerformance = 20
	scoreBattery     = 20
	scoreSecurity    = 20
	scoreMaintenance = 15
	scoreMole        = 5

	diskFreeWarning        = 0.20
	diskFreeCritical       = 0.10
	ramHighUsage           = 0.80
	ramMediumUsage         = 0.60
	swapHighGB             = 2.0
	swapMediumGB           = 0.5
	uptimeWarningDays      = 14
	uptimeCautionDays      = 7
	batteryCycleHigh       = 900
	batteryCycleMedium     = 500
	batteryHealthLow       = 80
	batteryHealthMed       = 90
	cacheRecoverableHighGB = 5.0
	cacheRecoverableMedGB  = 2.0
	brokenAgentsHigh       = 3
	unusedAppsHigh         = 5
	unusedAppsDays         = 90
	heavyProcessCPU        = 5.0
	heavyProcessMemMB      = 500
	heavyProcessMax        = 2
)

var spinnerFrames = []string{"|", "/", "-", "\\"}

const (
	colorPurple     = "\033[0;35m"
	colorPurpleBold = "\033[1;35m"
	colorGray       = "\033[0;90m"
	colorRed        = "\033[0;31m"
	colorYellow     = "\033[0;33m"
	colorGreen      = "\033[0;32m"
	colorBlue       = "\033[0;34m"
	colorCyan       = "\033[0;36m"
	colorReset      = "\033[0m"
	colorBold       = "\033[1m"
)
