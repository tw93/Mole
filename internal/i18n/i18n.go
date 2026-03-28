package i18n

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const (
	// 中文语言编码。
	LangZhCN = "zh-CN"
	// 英文语言编码。
	LangEnUS = "en-US"
)

var zhCatalog = map[string]string{
	"output metrics as JSON instead of TUI":                    "以 JSON 输出指标，而不是 TUI 界面",
	"output analysis as JSON instead of TUI":                   "以 JSON 输出分析结果，而不是 TUI 界面",
	"alert when a process stays above this CPU percent":         "当进程 CPU 持续高于该百分比时发出告警",
	"continuous duration a process must exceed the CPU threshold": "进程需要连续高于 CPU 阈值的时长",
	"enable persistent high-CPU process alerts":                "启用持续高 CPU 进程告警",
	"--proc-cpu-threshold must be >= 0":                        "--proc-cpu-threshold 必须 >= 0",
	"--proc-cpu-window must be > 0":                            "--proc-cpu-window 必须 > 0",
	"Loading...":                                               "加载中...",
	"error collecting metrics: %v":                             "采集指标失败：%v",
	"error encoding JSON: %v":                                  "编码 JSON 失败：%v",
	"system status error: %v":                                  "系统状态界面错误：%v",
	"cannot resolve %q: %v":                                    "无法解析 %q：%v",
	"analyzer error: %v":                                       "分析器错误：%v",
	"failed to encode JSON: %v":                                "编码 JSON 失败：%v",
	"failed to read directory: %v":                             "读取目录失败：%v",
	"Status":                                                   "状态",
	"Health ":                                                  "健康 ",
	"up %s":                                                    "运行 %s",
	"ERROR: %s":                                                "错误：%s",
	"ALERT %s at %.1f%% for %s (threshold %.1f%%)":             "告警 %s 已达 %.1f%%，持续 %s（阈值 %.1f%%）",
	" · +%d more":                                              " · 另有 %d 个",
	"Per-core data unavailable, using averaged load":           "无法获取单核数据，已使用平均负载",
	"CPU":                                                      "CPU",
	"Memory":                                                   "内存",
	"Disk":                                                     "磁盘",
	"Processes":                                                "进程",
	"Network":                                                  "网络",
	"Power":                                                    "电源",
	"Total  %s  %s":                                            "总计  %s  %s",
	"Core%-2d %s  %5.1f%%":                                     "核心%-2d %s  %5.1f%%",
	"Load   %.2f / %.2f / %.2f, %dP+%dE":                       "负载   %.2f / %.2f / %.2f，%dP+%dE",
	"Load   %.2f / %.2f / %.2f, %d cores":                      "负载   %.2f / %.2f / %.2f，%d 核",
	"Used   %s  %5.1f%%":                                       "已用  %s  %5.1f%%",
	"Free   %s  %5.1f%%":                                       "空闲  %s  %5.1f%%",
	"Swap   %s  %5.1f%%":                                       "交换  %s  %5.1f%%",
	"Total  %s / %s":                                           "总计  %s / %s",
	"Avail  %s":                                                "可用  %s",
	"Cached %s":                                                "缓存  %s",
	"Status %s":                                                "状态 %s",
	"Collecting...":                                            "采集中...",
	"No disks detected":                                        "未检测到磁盘",
	"Read   %s  %.1f MB/s":                                     "读取  %s  %.1f MB/s",
	"Write  %s  %.1f MB/s":                                     "写入  %s  %.1f MB/s",
	"%-6s %s  %s used, %s free":                                "%-6s %s  已用 %s，可用 %s",
	"No data":                                                  "无数据",
	"Down   %s  %s":                                            "下行  %s  %s",
	"Up     %s  %s":                                            "上行  %s  %s",
	"Proxy %s":                                                 "代理 %s",
	"No battery":                                               "无电池",
	"Level  %s  %s":                                            "电量  %s  %s",
	"Health %s  %s":                                            "健康  %s  %s",
	"%.0fW Adapter":                                            "%.0fW 适配器",
	"%d cycles":                                                "%d 次循环",
	"No Bluetooth info":                                        "无蓝牙信息",
	"No devices":                                               "无设备",
	"No GPU metrics available":                                 "无可用 GPU 指标",
	"Install nvidia-smi or use platform-specific metrics":      "请安装 nvidia-smi，或使用平台专用指标采集方式",
	"GPU read failed":                                          "GPU 读取失败",
	"Verify nvidia-smi availability":                           "请确认 nvidia-smi 可用",
	"GPU info unavailable":                                     "GPU 信息不可用",
	"Unable to parse system_profiler output":                   "无法解析 system_profiler 输出",
	"Unknown":                                                  "未知",
	"High CPU":                                                 "CPU 过高",
	"High Memory":                                              "内存占用过高",
	"Memory Pressure":                                          "内存压力高",
	"Critical Memory":                                          "内存严重不足",
	"Disk Almost Full":                                         "磁盘空间即将耗尽",
	"Overheating":                                              "温度过高",
	"Heavy Disk IO":                                            "磁盘 IO 负载高",
	"Excellent":                                                "优秀",
	"Good":                                                     "良好",
	"Fair":                                                     "一般",
	"Poor":                                                     "较差",
	"Critical":                                                 "严重",
	"normal":                                                   "正常",
	"warn":                                                     "警告",
	"critical":                                                 "严重",
	"charging":                                                 "充电中",
	"charged":                                                  "已充满",
	"discharging":                                              "放电中",
	"battery collection failed: %v":                            "电池信息采集失败：%v",
	"Analyze Disk":                                             "分析磁盘",
	"Analyzing disk usage, please wait...":                     "正在分析磁盘占用，请稍候...",
	"Select a location to explore:":                            "选择要查看的位置：",
	"Deleting: %s items removed, please wait...":               "正在删除：已移除 %s 项，请稍候...",
	"Scanning":                                                 "扫描中",
	"files":                                                    "文件",
	"dirs":                                                     "目录",
	"Total: %s":                                                "总计：%s",
	"No large files found":                                     "未发现大文件",
	"Empty directory":                                          "空目录",
	"Ready":                                                    "就绪",
	"Preparing scan...":                                        "正在准备扫描...",
	"Checking system folders...":                               "正在检查系统目录...",
	"Home":                                                     "主目录",
	"App Library":                                              "应用资料库",
	"Applications":                                             "应用程序",
	"System Library":                                           "系统资源库",
	"pending..":                                                "等待中..",
	"Scanning %s..., %d left":                                  "正在扫描 %s...，剩余 %d 个",
	"Scanning %d directories..., %d left":                      "正在扫描 %d 个目录...，剩余 %d 个",
	"Failed to delete: %v":                                     "删除失败：%v",
	"Deleted %d items":                                         "已删除 %d 项",
	"Scan failed: %v":                                          "扫描失败：%v",
	"Loaded cached data for %s, refreshing...":                 "已加载 %s 的缓存数据，正在刷新...",
	"Scanned %s":                                               "已扫描 %s",
	"Unable to measure %s: %v":                                 "无法统计 %s：%v",
	"Moving to Trash... %s items":                              "正在移到废纸篓... %s 项",
	"Nothing to delete":                                        "没有可删除的内容",
	"Deleting %s...":                                           "正在删除 %s...",
	"Deleting %d items...":                                     "正在删除 %d 项...",
	"Cancelled":                                                "已取消",
	"Refreshing...":                                            "正在刷新...",
	"Too many items to open, max %d, selected %d":              "要打开的项目过多，最多 %d 个，当前选中 %d 个",
	"Opening %d items...":                                      "正在打开 %d 项...",
	"Opening %s...":                                            "正在打开 %s...",
	"Too many items to reveal, max %d, selected %d":            "要在 Finder 中显示的项目过多，最多 %d 个，当前选中 %d 个",
	"Showing %d items in Finder...":                            "正在在 Finder 中显示 %d 项...",
	"Showing %s in Finder...":                                  "正在在 Finder 中显示 %s...",
	"%d selected, %s":                                          "已选择 %d 项，%s",
	"Scanning...":                                              "扫描中...",
	"Cached view for %s":                                       "已加载 %s 的缓存视图",
	"File: %s, %s":                                             "文件：%s，%s",
	"↑↓←→ | Enter | R Refresh | O Open | F File | Esc Back | Q/Ctrl+C Quit": "↑↓←→ | Enter | R 刷新 | O 打开 | F 定位 | Esc 返回 | Q/Ctrl+C 退出",
	"↑↓→ | Enter | R Refresh | O Open | F File | Esc/Q Quit":   "↑↓→ | Enter | R 刷新 | O 打开 | F 定位 | Esc/Q 退出",
	"↑↓← | Space Select | R Refresh | O Open | F File | ⌫ Del %d | Esc Back | Q/Ctrl+C Quit": "↑↓← | Space 选择 | R 刷新 | O 打开 | F 定位 | ⌫ 删除 %d | Esc 返回 | Q/Ctrl+C 退出",
	"↑↓← | Space Select | R Refresh | O Open | F File | ⌫ Del | Esc Back | Q/Ctrl+C Quit": "↑↓← | Space 选择 | R 刷新 | O 打开 | F 定位 | ⌫ 删除 | Esc 返回 | Q/Ctrl+C 退出",
	"↑↓←→ | Space Select | Enter | R Refresh | O Open | F File | ⌫ Del %d | T Top %d | Esc Back | Q/Ctrl+C Quit": "↑↓←→ | Space 选择 | Enter | R 刷新 | O 打开 | F 定位 | ⌫ 删除 %d | T 大文件 %d | Esc 返回 | Q/Ctrl+C 退出",
	"↑↓←→ | Space Select | Enter | R Refresh | O Open | F File | ⌫ Del %d | Esc Back | Q/Ctrl+C Quit": "↑↓←→ | Space 选择 | Enter | R 刷新 | O 打开 | F 定位 | ⌫ 删除 %d | Esc 返回 | Q/Ctrl+C 退出",
	"↑↓←→ | Space Select | Enter | R Refresh | O Open | F File | ⌫ Del | T Top %d | Esc Back | Q/Ctrl+C Quit": "↑↓←→ | Space 选择 | Enter | R 刷新 | O 打开 | F 定位 | ⌫ 删除 | T 大文件 %d | Esc 返回 | Q/Ctrl+C 退出",
	"↑↓←→ | Space Select | Enter | R Refresh | O Open | F File | ⌫ Del | Esc Back | Q/Ctrl+C Quit": "↑↓←→ | Space 选择 | Enter | R 刷新 | O 打开 | F 定位 | ⌫ 删除 | Esc 返回 | Q/Ctrl+C 退出",
	"Delete:":                                                  "删除：",
	"Press Enter to confirm  |  ESC cancel":                    "按 Enter 确认  |  ESC 取消",
	"Delete: %d items, %s":                                     "删除：%d 项，%s",
	"Delete: %s, %s":                                           "删除：%s，%s",
}

// normalize 负责把外部输入的语言值归一化为内部固定编码。
func normalize(lang string) string {
	lang = strings.TrimSpace(lang)
	lower := strings.ToLower(strings.ReplaceAll(lang, "_", "-"))
	switch {
	case lower == "zh", strings.HasPrefix(lower, "zh-"):
		return LangZhCN
	case lower == "en", strings.HasPrefix(lower, "en-"):
		return LangEnUS
	case lang == LangZhCN, lang == LangEnUS:
		return lang
	default:
		return ""
	}
}

// readSavedLanguage 读取 Mole 保存的语言配置。
func readSavedLanguage() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	data, err := os.ReadFile(filepath.Join(home, ".config", "mole", "language"))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "LANG=") {
			return normalize(strings.TrimPrefix(line, "LANG="))
		}
	}
	return ""
}

// Current 返回当前会话的语言编码。
func Current() string {
	if lang := normalize(os.Getenv("MOLE_LANG")); lang != "" {
		return lang
	}
	if lang := readSavedLanguage(); lang != "" {
		return lang
	}
	return LangEnUS
}

// IsChinese 判断当前语言是否为中文。
func IsChinese() bool {
	return Current() == LangZhCN
}

// T 返回翻译后的文案；未命中时回退原文。
func T(key string) string {
	if IsChinese() {
		if value, ok := zhCatalog[key]; ok {
			return value
		}
	}
	return key
}

// F 对翻译后的格式化模板执行 Sprintf。
func F(format string, args ...any) string {
	return fmt.Sprintf(T(format), args...)
}
