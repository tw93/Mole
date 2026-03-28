# Mole I18n and Language Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Chinese/English i18n with first-run language selection, persisted language config, language switching, and translated user-facing text in Bash and Go entry flows.

**Architecture:** Add a Bash i18n layer under `lib/core` plus localized catalogs for shell output, and add a small shared Go i18n package that loads the same persisted language choice or `MOLE_LANG`. Wire the selection flow into the main `mo` entrypoint and pass language context into Go binaries through shell wrappers.

**Tech Stack:** Bash 3.2, Bats, Go 1.25, Bubble Tea, Lip Gloss

---

### Task 1: 语言配置与 Bash 基础设施

**Files:**
- Create: `/Users/fengjinyi/Desktop/script/i18n/Mole/lib/core/i18n.sh`
- Create: `/Users/fengjinyi/Desktop/script/i18n/Mole/lib/i18n/zh_cn.sh`
- Create: `/Users/fengjinyi/Desktop/script/i18n/Mole/lib/i18n/en_us.sh`
- Modify: `/Users/fengjinyi/Desktop/script/i18n/Mole/lib/core/common.sh`
- Test: `/Users/fengjinyi/Desktop/script/i18n/Mole/tests/cli.bats`

- [ ] 写失败测试：覆盖首次语言选择、语言配置读写、`--help`/主菜单中文输出
- [ ] 运行测试确认失败
- [ ] 实现最小 Bash i18n 层与语言配置解析
- [ ] 再次运行测试确认通过

### Task 2: 主入口与核心 Bash 文案接入

**Files:**
- Modify: `/Users/fengjinyi/Desktop/script/i18n/Mole/mole`
- Modify: `/Users/fengjinyi/Desktop/script/i18n/Mole/lib/core/help.sh`
- Modify: `/Users/fengjinyi/Desktop/script/i18n/Mole/lib/core/commands.sh`
- Modify: `/Users/fengjinyi/Desktop/script/i18n/Mole/bin/status.sh`
- Modify: `/Users/fengjinyi/Desktop/script/i18n/Mole/bin/analyze.sh`
- Test: `/Users/fengjinyi/Desktop/script/i18n/Mole/tests/cli.bats`

- [ ] 写失败测试：覆盖 `mo language`、`L` 切换语言、包装脚本语言透传
- [ ] 运行测试确认失败
- [ ] 接入主菜单、help、版本、错误提示、Go wrapper 文案
- [ ] 再次运行测试确认通过

### Task 3: Go 侧共享 i18n 与 status 文案

**Files:**
- Create: `/Users/fengjinyi/Desktop/script/i18n/Mole/internal/i18n/i18n.go`
- Modify: `/Users/fengjinyi/Desktop/script/i18n/Mole/cmd/status/main.go`
- Modify: `/Users/fengjinyi/Desktop/script/i18n/Mole/cmd/status/view.go`
- Modify: `/Users/fengjinyi/Desktop/script/i18n/Mole/cmd/status/metrics_*.go`
- Test: `/Users/fengjinyi/Desktop/script/i18n/Mole/cmd/status/view_test.go`
- Test: `/Users/fengjinyi/Desktop/script/i18n/Mole/cmd/status/process_watch_test.go`

- [ ] 写失败测试：覆盖中文 header、告警条、状态卡关键文案
- [ ] 运行 Go 测试确认失败
- [ ] 实现 Go i18n 加载与 status 关键文案翻译
- [ ] 再次运行测试确认通过

### Task 4: analyze 文案与操作状态翻译

**Files:**
- Modify: `/Users/fengjinyi/Desktop/script/i18n/Mole/cmd/analyze/main.go`
- Modify: `/Users/fengjinyi/Desktop/script/i18n/Mole/cmd/analyze/view.go`
- Test: `/Users/fengjinyi/Desktop/script/i18n/Mole/cmd/analyze/*_test.go`

- [ ] 写失败测试：覆盖 overview/header/status/删除确认相关文案
- [ ] 运行 Go 测试确认失败
- [ ] 实现 analyze 关键文案翻译
- [ ] 再次运行测试确认通过

### Task 5: 回归验证

**Files:**
- Test: `/Users/fengjinyi/Desktop/script/i18n/Mole/tests/cli.bats`
- Test: `/Users/fengjinyi/Desktop/script/i18n/Mole/tests/completion.bats`
- Test: `/Users/fengjinyi/Desktop/script/i18n/Mole/cmd/status/...`
- Test: `/Users/fengjinyi/Desktop/script/i18n/Mole/cmd/analyze/...`

- [ ] 运行 Bash 相关测试
- [ ] 运行 Go 相关测试
- [ ] 修复回归并重复验证直到稳定
