//go:build darwin

package main

import (
	"strings"
	"testing"
)

func TestOverviewViewUsesChineseWhenRequested(t *testing.T) {
	t.Setenv("MOLE_LANG", "zh-CN")

	m := model{
		path:       "/",
		isOverview: true,
		entries: []dirEntry{
			{Name: "Home", Path: "/Users/test", IsDir: true, Size: 1024},
		},
		status: "Ready",
	}

	view := m.View()
	if !strings.Contains(view, "分析磁盘") {
		t.Fatalf("View() should render Chinese title, got %q", view)
	}
	if !strings.Contains(view, "选择要查看的位置") {
		t.Fatalf("View() should render Chinese overview hint, got %q", view)
	}
}
