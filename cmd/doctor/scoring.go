//go:build darwin

package main

import (
	"fmt"
	"strings"
)

func buildCategory(name string, maxScore int, checks []checkResult) categoryResult {
	cat := categoryResult{
		Name:     name,
		MaxScore: maxScore,
		Checks:   checks,
	}
	for _, c := range checks {
		cat.Score += c.Score
	}
	if cat.Score > cat.MaxScore {
		cat.Score = cat.MaxScore
	}
	return cat
}

func calculateTotalScore(categories []categoryResult) (int, int) {
	total := 0
	max := 0
	for _, c := range categories {
		total += c.Score
		max += c.MaxScore
	}
	return total, max
}

func redistributeBatteryScore(categories []categoryResult) []categoryResult {
	hasBattery := false
	for _, c := range categories {
		if c.Name == "Battery" && c.MaxScore > 0 {
			hasBattery = true
			break
		}
	}
	if hasBattery {
		return categories
	}

	nonBatteryCount := 0
	for _, c := range categories {
		if c.Name != "Battery" {
			nonBatteryCount++
		}
	}
	if nonBatteryCount == 0 {
		return categories
	}

	extra := scoreBattery / nonBatteryCount
	remainder := scoreBattery % nonBatteryCount

	result := make([]categoryResult, 0, len(categories))
	idx := 0
	for _, c := range categories {
		if c.Name == "Battery" {
			continue
		}
		bonus := extra
		if idx < remainder {
			bonus++
		}
		originalMax := c.MaxScore
		c.MaxScore += bonus
		if originalMax > 0 {
			c.Score = (c.Score*c.MaxScore + originalMax/2) / originalMax
			c.Score = min(c.Score, c.MaxScore)
		}
		result = append(result, c)
		idx++
	}
	return result
}

func generateTips(categories []categoryResult) []string {
	var tips []string

	for _, c := range categories {
		if c.MaxScore == 0 {
			continue
		}
		ratio := float64(c.Score) / float64(c.MaxScore)
		if ratio >= 0.8 {
			continue
		}

		switch c.Name {
		case "Storage":
			for _, check := range c.Checks {
				if check.Name == "Recoverable cache" && check.Status != statusPass {
					tips = append(tips, "Run 'mo clean' to reclaim cache space")
				}
				if check.Name == "node_modules" && check.Status != statusPass {
					tips = append(tips, "Run 'mo clean' to prune old node_modules")
				}
				if check.Name == "iOS backups" && check.Status != statusPass {
					tips = append(tips, "Old iOS backups are using disk space — remove in Finder > Manage Storage")
				}
			}
		case "Performance":
			for _, check := range c.Checks {
				if check.Name == "Uptime" && check.Status != statusPass {
					tips = append(tips, "A restart can free memory and clear temp files")
				}
				if check.Name == "Swap usage" && check.Status != statusPass {
					tips = append(tips, "Consider closing some apps to reduce swap usage")
				}
			}
		case "Battery":
			for _, check := range c.Checks {
				if check.Status != statusPass {
					tips = append(tips, "Battery health is low — consider Apple service")
					break
				}
			}
		case "Security":
			var secNames []string
			for _, check := range c.Checks {
				if check.Status != statusPass {
					secNames = append(secNames, check.Name)
				}
			}
			if len(secNames) > 0 {
				tips = append(tips, fmt.Sprintf("%s not enabled — check System Settings", strings.Join(secNames, ", ")))
			}
		case "Maintenance":
			for _, check := range c.Checks {
				if check.Name == "Broken launch agents" && check.Status != statusPass {
					tips = append(tips, "Run 'mo optimize' to fix broken launch agents")
				}
				if check.Name == "Heavy processes" && check.Status != statusPass {
					tips = append(tips, "Close heavy background processes to improve performance")
				}
			}
		case "Dev Environment":
			for _, check := range c.Checks {
				if check.Name == "Common tools" && check.Status != statusPass {
					tips = append(tips, check.Detail)
				}
				if check.Name == "IDE extensions" && check.Status != statusPass {
					tips = append(tips, "Remove duplicate IDE extensions to save disk and avoid conflicts")
				}
			}
		case "Mole":
			for _, check := range c.Checks {
				if check.Name == "Version" && check.Status != statusPass {
					tips = append(tips, "Run 'mo update' to get the latest version")
				}
			}
		}
	}

	if len(tips) == 0 {
		tips = append(tips, "Your Mac is in great shape!")
	}
	return tips
}
