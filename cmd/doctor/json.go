//go:build darwin

package main

import (
	"encoding/json"
	"fmt"
	"os"
)

type jsonCheckOutput struct {
	Name     string `json:"name"`
	Status   string `json:"status"`
	Detail   string `json:"detail"`
	Score    int    `json:"score"`
	MaxScore int    `json:"max_score"`
}

type jsonCategoryOutput struct {
	Name     string            `json:"name"`
	Score    int               `json:"score"`
	MaxScore int               `json:"max_score"`
	Checks   []jsonCheckOutput `json:"checks"`
}

type jsonDiagnosisOutput struct {
	TotalScore int                  `json:"total_score"`
	MaxScore   int                  `json:"max_score"`
	Categories []jsonCategoryOutput `json:"categories"`
	Tips       []string             `json:"tips"`
}

func statusString(s checkStatus) string {
	switch s {
	case statusPass:
		return "pass"
	case statusWarn:
		return "warn"
	case statusFail:
		return "fail"
	case statusSkipped:
		return "skipped"
	default:
		return "unknown"
	}
}

func runJSONMode() {
	result := runAllChecks(*hasSudo)

	output := jsonDiagnosisOutput{
		TotalScore: result.TotalScore,
		MaxScore:   result.MaxScore,
		Tips:       result.Tips,
	}

	for _, cat := range result.Categories {
		jCat := jsonCategoryOutput{
			Name:     cat.Name,
			Score:    cat.Score,
			MaxScore: cat.MaxScore,
		}
		for _, check := range cat.Checks {
			jCat.Checks = append(jCat.Checks, jsonCheckOutput{
				Name:     check.Name,
				Status:   statusString(check.Status),
				Detail:   check.Detail,
				Score:    check.Score,
				MaxScore: check.MaxScore,
			})
		}
		output.Categories = append(output.Categories, jCat)
	}

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(output); err != nil {
		fmt.Fprintf(os.Stderr, "failed to encode JSON: %v\n", err)
		os.Exit(1)
	}
}
