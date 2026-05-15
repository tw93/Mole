package locale

// zhMessages contains Simplified Chinese UI strings for the TUI components.
var zhMessages = map[string]string{
	// ── 系统状态 TUI ────────────────────────────────────────────────
	"status.title":        "系统状态",
	"status.health":       "健康",
	"status.loading":      "加载中...",
	"status.error":        "错误",

	// 处理器
	"cpu.title":           "处理器",
	"cpu.total":           "总计",
	"cpu.load":            "负载",
	"cpu.core":            "核心",
	"cpu.per_core_na":     "单核数据不可用，使用平均负载",
	"cpu.cores":           "核",

	// 内存
	"memory.title":        "内存",
	"memory.used":         "已用",
	"memory.free":         "空闲",
	"memory.swap":         "交换",
	"memory.total":        "合计",
	"memory.avail":        "可用",
	"memory.cached":       "缓存",
	"memory.status":       "状态",

	// 磁盘
	"disk.title":          "磁盘",
	"disk.read":           "读取",
	"disk.write":          "写入",
	"disk.trash":          "废纸篓",
	"disk.total":          "合计",
	"disk.used":           "已用",
	"disk.free":           "可用",
	"disk.collecting":     "正在收集...",
	"disk.no_disks":       "未检测到磁盘",

	// 网络
	"network.title":       "网络",
	"network.down":        "下行",
	"network.up":          "上行",
	"network.proxy":       "代理",

	// 电源
	"power.title":         "电源",
	"power.level":         "电量",
	"power.health":        "健康",
	"power.input":         "输入",
	"power.no_battery":    "无电池",
	"power.unknown":       "未知",
	"power.ac":            "交流电",
	"power.charged":       "已充满",
	"power.charging":      "充电中",
	"power.discharging":   "使用电池",
	"power.adapter":       "适配器",
	"power.max":           "最大",
	"power.cycles":        "循环",
	"power.battery":       "电池",

	// 进程
	"process.title":       "进程",
	"process.no_data":     "暂无数据",

	// 健康评分
	"health.excellent":    "优秀",
	"health.good":         "良好",
	"health.fair":         "一般",
	"health.poor":         "较差",
	"health.critical":     "严重",
	"health.high_cpu":     "CPU 占用过高",
	"health.high_mem":     "内存占用过高",
	"health.mem_pressure": "内存压力",
	"health.crit_mem":     "内存严重不足",
	"health.disk_full":    "磁盘空间即将用尽",
	"health.overheat":     "过热",
	"health.heavy_io":     "磁盘 IO 繁忙",
	"health.bat_service":  "电池需要维修",
	"health.restart":      "建议重启",

	// 电池健康
	"bat.service_soon":    "需要维修",
	"bat.fair":            "一般",
	"bat.healthy":         "健康",

	// 告警
	"alert.prefix":        "告警",
	"alert.more":          "+%d 更多",
	"alert.threshold":     "阈值",
	"alert.for":           "持续",
	"alert.at":            "于",

	// ── 磁盘分析 TUI ────────────────────────────────────────────────
	"analyze.title":       "磁盘分析",
	"analyze.select":      "选择要探索的位置：",
	"analyze.scanning":    "正在扫描",
	"analyze.analyzing":   "正在分析磁盘用量...",
	"analyze.deleting":    "正在删除：",
	"analyze.items":       "个项目",
	"analyze.removed":     "已删除，请稍候...",
	"analyze.files":       "文件",
	"analyze.dirs":        "目录",
	"analyze.empty_dir":   "空目录",
	"analyze.no_large":    "未发现大文件",
	"analyze.total":       "总计：",
	"analyze.pending":     "计算中..",
	"analyze.free":        "可用",

	// 分析状态消息
	"analyze.preparing":   "正在准备扫描...",
	"analyze.checking":    "正在检查系统目录...",
	"analyze.ready":       "就绪",
	"analyze.refreshing":  "正在刷新...",
	"analyze.scan_failed": "扫描失败：%v",
	"analyze.del_failed":  "删除失败：%v",
	"analyze.deleted":     "已删除 %d 个项目",
	"analyze.nothing":     "没有要删除的内容",
	"analyze.cancelled":   "已取消",
	"analyze.del_items":   "正在删除 %d 个项目...",
	"analyze.del_single":  "正在删除 %s...",
	"analyze.moving":      "正在移至废纸篓... %s 个项目",
	"analyze.cached":      "已加载 %s 的缓存数据，正在刷新...",
	"analyze.scanned":     "已扫描 %s",
	"analyze.scan_dir":    "正在扫描 %s...，剩余 %d",
	"analyze.scan_dirs":   "正在扫描 %d 个目录...，剩余 %d",
	"analyze.unable":      "无法测量 %s：%v",
	"analyze.opening":     "正在打开 %s...",
	"analyze.open_items":  "正在打开 %d 个项目...",
	"analyze.open_max":    "打开项目过多，最多 %d 个，已选 %d 个",

	// 删除确认
	"analyze.del_confirm_multi":  "删除：",
	"analyze.del_confirm_single": "删除：",
	"analyze.del_press":          "按 回车 确认  |  ESC 取消",

	// 底部快捷键提示
	"analyze.keys_overview":      "↑↓←→ | 回车 | R 刷新 | O 打开 | P 预览 | F 文件 | Esc 返回 | Q/Ctrl+C 退出",
	"analyze.keys_overview_root": "↑↓→ | 回车 | R 刷新 | O 打开 | P 预览 | F 文件 | Esc/Q 退出",
	"analyze.keys_large":         "↑↓← | 空格 选择 | R 刷新 | O 打开 | P 预览 | F 文件 | ⌫ 删除 | Esc 返回 | Q/Ctrl+C 退出",
	"analyze.keys_large_sel":     "↑↓← | 空格 选择 | R 刷新 | O 打开 | P 预览 | F 文件 | ⌫ 删除 %d | Esc 返回 | Q/Ctrl+C 退出",
	"analyze.keys_dir":           "↑↓←→ | 空格 选择 | 回车 | R 刷新 | O 打开 | P 预览 | F 文件 | ⌫ 删除 | Esc 返回 | Q/Ctrl+C 退出",
	"analyze.keys_dir_sel":       "↑↓←→ | 空格 选择 | 回车 | R 刷新 | O 打开 | P 预览 | F 文件 | ⌫ 删除 %d | Esc 返回 | Q/Ctrl+C 退出",
	"analyze.keys_dir_top":       "↑↓←→ | 空格 选择 | 回车 | R 刷新 | O 打开 | P 预览 | F 文件 | ⌫ 删除 | T 大文件 %d | Esc 返回 | Q/Ctrl+C 退出",
	"analyze.keys_dir_sel_top":   "↑↓←→ | 空格 选择 | 回车 | R 刷新 | O 打开 | P 预览 | F 文件 | ⌫ 删除 %d | T 大文件 %d | Esc 返回 | Q/Ctrl+C 退出",

	// 概览名称
	"overview.home":           "主目录",
	"overview.user_library":   "用户资源库",
	"overview.applications":   "应用程序",
	"overview.system_library": "系统资源库",

	// 运行时间
	"uptime.prefix": "已运行",
}
