#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Screen {
    MainMenu,
    Clean,
    Uninstall,
    Optimize,
    Analyze,
    Status,
}

impl Screen {
    /// List of sub-screens accessible from the main menu.
    pub fn menu_items() -> &'static [Screen] {
        &[
            Screen::Clean,
            Screen::Uninstall,
            Screen::Optimize,
            Screen::Analyze,
            Screen::Status,
        ]
    }

    /// Display name of the screen.
    pub fn display_name(&self) -> &'static str {
        match self {
            Screen::MainMenu => "Main Menu",
            Screen::Clean => "Clean",
            Screen::Uninstall => "Uninstall",
            Screen::Optimize => "Optimize",
            Screen::Analyze => "Analyze",
            Screen::Status => "Status",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UninstallItem {
    pub name: String,
    pub size_mb: u64,
    pub last_used: String,
    pub selected: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CleanStatus {
    Pending,
    InProgress,
    Success,
    Skipped,
    Info,
    Error,
}

#[derive(Debug, Clone)]
pub struct CleanTask {
    pub name: String,
    pub status: CleanStatus,
    pub detail: String,
}

#[derive(Debug, Clone)]
pub struct CleanCategory {
    pub name: String,
    pub tasks: Vec<CleanTask>,
}

pub struct App {
    pub current_screen: Screen,
    pub menu_index: usize,
    pub should_quit: bool,

    // Uninstall screen state
    pub uninstall_items: Vec<UninstallItem>,
    pub uninstall_search: String,
    pub uninstall_searching: bool,
    pub uninstall_index: usize,
    pub uninstall_confirm_open: bool,

    // Clean screen state
    pub clean_categories: Vec<CleanCategory>,
    pub clean_running: bool,
    pub clean_error: Option<String>,
    pub active_category_idx: Option<usize>,
    pub spinner_frame: usize,
    pub clean_bytes_target: u64,
    pub clean_bytes_displayed: u64,
    pub clean_progress_displayed: f64,

    // Animation / transition states
    pub menu_prev_index: Option<usize>,
    pub menu_transition_ticks: usize,
    pub uninstall_prev_index: Option<usize>,
    pub uninstall_transition_ticks: usize,

    // Global error banner state
    pub global_error: Option<String>,

    // Uninstall scanner state
    pub uninstall_scanning_status: bool,
}

impl Default for App {
    fn default() -> Self {
        Self::new()
    }
}

impl App {
    pub fn new() -> Self {
        Self {
            current_screen: Screen::MainMenu,
            menu_index: 0,
            should_quit: false,
            uninstall_items: Vec::new(),
            uninstall_search: String::new(),
            uninstall_searching: false,
            uninstall_index: 0,
            uninstall_confirm_open: false,
            clean_categories: Vec::new(),
            clean_running: false,
            clean_error: None,
            active_category_idx: None,
            spinner_frame: 0,
            clean_bytes_target: 0,
            clean_bytes_displayed: 0,
            clean_progress_displayed: 0.0,
            menu_prev_index: None,
            menu_transition_ticks: 0,
            uninstall_prev_index: None,
            uninstall_transition_ticks: 0,
            global_error: None,
            uninstall_scanning_status: true,
        }
    }

    /// Navigate to the next menu item.
    pub fn next_menu_item(&mut self) {
        let count = Screen::menu_items().len();
        if count > 0 {
            self.menu_prev_index = Some(self.menu_index);
            self.menu_transition_ticks = 3; // 3 ticks (240ms) transition fade
            self.menu_index = (self.menu_index + 1) % count;
        }
    }

    /// Navigate to the previous menu item.
    pub fn previous_menu_item(&mut self) {
        let count = Screen::menu_items().len();
        if count > 0 {
            self.menu_prev_index = Some(self.menu_index);
            self.menu_transition_ticks = 3;
            if self.menu_index == 0 {
                self.menu_index = count - 1;
            } else {
                self.menu_index -= 1;
            }
        }
    }

    /// Switch to the currently selected screen from the menu.
    pub fn select_current_menu_item(&mut self) {
        if self.current_screen == Screen::MainMenu {
            let items = Screen::menu_items();
            if self.menu_index < items.len() {
                self.current_screen = items[self.menu_index];
                // Reset screen states upon entry
                if self.current_screen == Screen::Uninstall {
                    self.uninstall_index = 0;
                    self.uninstall_search.clear();
                    self.uninstall_searching = false;
                    self.uninstall_confirm_open = false;
                } else if self.current_screen == Screen::Clean {
                    self.clean_categories.clear();
                    self.clean_running = false;
                    self.clean_error = None;
                    self.active_category_idx = None;
                    self.clean_bytes_target = 0;
                    self.clean_bytes_displayed = 0;
                    self.clean_progress_displayed = 0.0;
                }
            }
        }
    }

    /// Return to the Main Menu, or quit if already there.
    pub fn go_back(&mut self) {
        match self.current_screen {
            Screen::MainMenu => {
                self.should_quit = true;
            }
            _ => {
                self.current_screen = Screen::MainMenu;
                self.clean_running = false;
            }
        }
    }

    /// Set the quit flag.
    pub fn quit(&mut self) {
        self.should_quit = true;
    }

    // --- Animation and key cancellation handlers ---

    /// Process the 80ms Tick events to advance spinners and smooth interpolation animations
    pub fn handle_tick(&mut self) {
        // 1. Advance clean bytes freed display smoothly
        if self.clean_bytes_displayed < self.clean_bytes_target {
            let diff = self.clean_bytes_target - self.clean_bytes_displayed;
            let step = (diff / 10).max(1024 * 1024); // 1 MB minimum increment step
            if step >= diff {
                self.clean_bytes_displayed = self.clean_bytes_target;
            } else {
                self.clean_bytes_displayed += step;
            }
        }

        // 2. Advance clean progress bar percentage smoothly
        let total_tasks = self.clean_categories.iter().map(|c| c.tasks.len()).sum::<usize>();
        let completed_tasks = self.clean_categories.iter()
            .map(|c| c.tasks.iter().filter(|t| matches!(t.status, CleanStatus::Success | CleanStatus::Skipped | CleanStatus::Info | CleanStatus::Error)).count())
            .sum::<usize>();
        let target_progress = if total_tasks > 0 { completed_tasks as f64 / total_tasks as f64 } else { 0.0 };

        if self.clean_progress_displayed < target_progress {
            self.clean_progress_displayed = (self.clean_progress_displayed + 0.05).min(target_progress);
        }

        // 3. Decrement visual transition fade ticks
        if self.menu_transition_ticks > 0 {
            self.menu_transition_ticks -= 1;
            if self.menu_transition_ticks == 0 {
                self.menu_prev_index = None;
            }
        }
        if self.uninstall_transition_ticks > 0 {
            self.uninstall_transition_ticks -= 1;
            if self.uninstall_transition_ticks == 0 {
                self.uninstall_prev_index = None;
            }
        }
    }

    /// Instantly skip all ongoing animations to their final values upon any keypress
    pub fn cancel_animations(&mut self) {
        self.clean_bytes_displayed = self.clean_bytes_target;
        
        let total_tasks = self.clean_categories.iter().map(|c| c.tasks.len()).sum::<usize>();
        let completed_tasks = self.clean_categories.iter()
            .map(|c| c.tasks.iter().filter(|t| matches!(t.status, CleanStatus::Success | CleanStatus::Skipped | CleanStatus::Info | CleanStatus::Error)).count())
            .sum::<usize>();
        self.clean_progress_displayed = if total_tasks > 0 { completed_tasks as f64 / total_tasks as f64 } else { 0.0 };

        self.menu_prev_index = None;
        self.menu_transition_ticks = 0;
        self.uninstall_prev_index = None;
        self.uninstall_transition_ticks = 0;
    }

    // --- Uninstall screen state updates ---

    /// Returns the filtered uninstall items list alongside their original indices.
    pub fn filtered_uninstall_items(&self) -> Vec<(usize, &UninstallItem)> {
        self.uninstall_items
            .iter()
            .enumerate()
            .filter(|(_, item)| {
                self.uninstall_search.is_empty()
                    || item.name.to_lowercase().contains(&self.uninstall_search.to_lowercase())
            })
            .collect()
    }

    /// Navigate to the next item on the uninstall list.
    pub fn uninstall_next(&mut self) {
        let count = self.filtered_uninstall_items().len();
        if count > 0 {
            self.uninstall_prev_index = Some(self.uninstall_index);
            self.uninstall_transition_ticks = 3;
            self.uninstall_index = (self.uninstall_index + 1) % count;
        }
    }

    /// Navigate to the previous item on the uninstall list.
    pub fn uninstall_prev(&mut self) {
        let count = self.filtered_uninstall_items().len();
        if count > 0 {
            self.uninstall_prev_index = Some(self.uninstall_index);
            self.uninstall_transition_ticks = 3;
            if self.uninstall_index == 0 {
                self.uninstall_index = count - 1;
            } else {
                self.uninstall_index -= 1;
            }
        }
    }

    /// Toggle selection of the currently highlighted uninstall item.
    pub fn uninstall_toggle(&mut self) {
        let filtered = self.filtered_uninstall_items();
        if self.uninstall_index < filtered.len() {
            let (original_idx, _) = filtered[self.uninstall_index];
            self.uninstall_items[original_idx].selected = !self.uninstall_items[original_idx].selected;
        }
    }

    /// Update search query and automatically clamp the index.
    pub fn uninstall_update_search(&mut self, query: String) {
        self.uninstall_search = query;
        let count = self.filtered_uninstall_items().len();
        if count == 0 {
            self.uninstall_index = 0;
        } else if self.uninstall_index >= count {
            self.uninstall_index = count - 1;
        }
    }

    // --- Clean screen execution updates ---

    /// Trigger the cleanup process asynchronously by invoking clean.sh
    pub fn start_clean_execution(&mut self, event_tx: tokio::sync::mpsc::Sender<crate::AppEvent>) {
        if self.clean_running {
            return;
        }
        self.clean_categories = initial_categories();
        self.clean_running = true;
        self.clean_error = None;
        self.active_category_idx = None;
        self.spinner_frame = 0;
        self.clean_bytes_target = 0;
        self.clean_bytes_displayed = 0;
        self.clean_progress_displayed = 0.0;

        let envs = vec![
            ("MOLE_DRY_RUN".to_string(), "1".to_string()),
            ("MOLE_TEST_NO_AUTH".to_string(), "1".to_string()),
        ];
        let mut script_rx = crate::scripts::run_script("bin/clean.sh", vec![], envs);
        
        tokio::spawn(async move {
            while let Some(event) = script_rx.recv().await {
                if event_tx.send(crate::AppEvent::Script(event)).await.is_err() {
                    break;
                }
            }
        });
    }

    pub fn handle_clean_event(&mut self, event: crate::scripts::ScriptEvent) {
        match event {
            crate::scripts::ScriptEvent::Line(line) => {
                self.parse_and_update_clean_line(&line);
            }
            crate::scripts::ScriptEvent::Finished(result) => {
                self.clean_running = false;
                match result {
                    Ok(code) => {
                        if code != 0 {
                            self.clean_error = Some(format!("Exit code: {}", code));
                        }
                    }
                    Err(err) => {
                        self.clean_error = Some(err);
                    }
                }
            }
        }
    }

    pub fn parse_and_update_clean_line(&mut self, line: &str) {
        let parsed = parse_line(line);
        match parsed {
            LineParsed::Category(cat_name) => {
                if let Some(pos) = self
                    .clean_categories
                    .iter()
                    .position(|c| c.name.to_lowercase() == cat_name.to_lowercase())
                {
                    self.active_category_idx = Some(pos);
                } else {
                    self.clean_categories.push(CleanCategory {
                        name: cat_name,
                        tasks: Vec::new(),
                    });
                    self.active_category_idx = Some(self.clean_categories.len() - 1);
                }

                // Set first pending task of this new active category to InProgress
                if let Some(idx) = self.active_category_idx {
                    if let Some(first_task) = self.clean_categories[idx]
                        .tasks
                        .iter_mut()
                        .find(|t| t.status == CleanStatus::Pending)
                    {
                        first_task.status = CleanStatus::InProgress;
                    }
                }
            }
            LineParsed::Task { status, text } => {
                let active_idx = match self.active_category_idx {
                    Some(idx) => idx,
                    None => {
                        self.clean_categories.push(CleanCategory {
                            name: "General".to_string(),
                            tasks: Vec::new(),
                        });
                        let idx = self.clean_categories.len() - 1;
                        self.active_category_idx = Some(idx);
                        idx
                    }
                };

                if active_idx >= self.clean_categories.len() {
                    return;
                }

                // Match prefix of the task name
                let mut matched_idx = None;
                for (i, task) in self.clean_categories[active_idx].tasks.iter().enumerate() {
                    if text.to_lowercase().starts_with(&task.name.to_lowercase()) {
                        matched_idx = Some(i);
                        break;
                    }
                }

                if let Some(idx) = matched_idx {
                    let task = &mut self.clean_categories[active_idx].tasks[idx];
                    task.status = status;
                    let detail = text[task.name.len()..]
                        .trim()
                        .trim_start_matches('·')
                        .trim_start_matches(',')
                        .trim()
                        .to_string();
                    task.detail = detail.clone();

                    // Accumulate size bytes
                    let bytes = parse_bytes_from_detail(&detail);
                    self.clean_bytes_target += bytes;

                    // Advance status of the next pending task in the list to InProgress
                    if let Some(next_task) = self.clean_categories[active_idx]
                        .tasks
                        .iter_mut()
                        .skip(idx + 1)
                        .find(|t| t.status == CleanStatus::Pending)
                    {
                        next_task.status = CleanStatus::InProgress;
                    }
                } else {
                    // Dynamically append new task if not pre-registered in lists
                    let mut name = text.clone();
                    let mut detail = String::new();

                    if let Some(pos) = text.find(" · ") {
                        name = text[..pos].trim().to_string();
                        detail = text[pos + 3..].trim().to_string();
                    } else if let Some(pos) = text.find(", ") {
                        name = text[..pos].trim().to_string();
                        detail = text[pos + 2..].trim().to_string();
                    } else if let Some(pos) = text.find(" items") {
                        let words: Vec<&str> = text[..pos].split_whitespace().collect();
                        if !words.is_empty() {
                            let last_word = words[words.len() - 1];
                            if last_word.chars().all(|c| c.is_digit(10)) {
                                let name_len = text[..pos].len() - last_word.len() - 1;
                                name = text[..name_len].trim().to_string();
                                detail = text[name_len..].trim().to_string();
                            }
                        }
                    }

                    // Accumulate size bytes
                    let bytes = parse_bytes_from_detail(&detail);
                    self.clean_bytes_target += bytes;

                    self.clean_categories[active_idx].push_task(CleanTask {
                        name,
                        status,
                        detail,
                    });
                }
            }
            LineParsed::Raw(raw_line) => {
                let active_idx = self.active_category_idx.unwrap_or(0);
                if active_idx < self.clean_categories.len() {
                    let raw_line_clean = raw_line.trim().to_string();
                    if !raw_line_clean.is_empty()
                        && !raw_line_clean.contains("Clean Your Mac")
                        && !raw_line_clean.contains("Running in non-interactive")
                    {
                        self.clean_categories[active_idx].tasks.push(CleanTask {
                            name: raw_line_clean,
                            status: CleanStatus::Info,
                            detail: String::new(),
                        });
                    }
                }
            }
            LineParsed::Empty => {}
        }
    }
}

impl CleanCategory {
    fn push_task(&mut self, task: CleanTask) {
        self.tasks.push(task);
    }
}

pub fn initial_categories() -> Vec<CleanCategory> {
    vec![
        CleanCategory {
            name: "User essentials".to_string(),
            tasks: vec![
                CleanTask {
                    name: "User app cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "User app logs".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Trash".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
            ],
        },
        CleanCategory {
            name: "App caches".to_string(),
            tasks: vec![
                CleanTask {
                    name: "Media analysis cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Media analysis temp files".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "macOS Help system cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Parsecd cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Group Containers logs/caches".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
            ],
        },
        CleanCategory {
            name: "Browsers".to_string(),
            tasks: vec![
                CleanTask {
                    name: "Chrome cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Chrome Service Worker".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "GoogleUpdater CRX cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Google Chrome running status".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
            ],
        },
        CleanCategory {
            name: "Cloud & Office".to_string(),
            tasks: vec![CleanTask {
                name: "Cloud & Office cleanup".to_string(),
                status: CleanStatus::Pending,
                detail: String::new(),
            }],
        },
        CleanCategory {
            name: "Developer tools".to_string(),
            tasks: vec![
                CleanTask {
                    name: "npm cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "npm npx cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "npm logs".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "pnpm cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Corepack cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "pip cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "uv cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Go cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Rust cargo cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Rust toolchains".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Docker unused data".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "OrbStack container data".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Oh My Zsh cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Simulator cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Xcode runtime volumes".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Xcode unavailable simulators".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Sentry crash reports".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Homebrew cache".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
                CleanTask {
                    name: "Homebrew cleanup".to_string(),
                    status: CleanStatus::Pending,
                    detail: String::new(),
                },
            ],
        },
        CleanCategory {
            name: "Applications".to_string(),
            tasks: vec![CleanTask {
                name: "Applications cleanup".to_string(),
                status: CleanStatus::Pending,
                detail: String::new(),
            }],
        },
    ]
}

#[derive(Debug, Clone)]
pub enum LineParsed {
    Category(String),
    Task { status: CleanStatus, text: String },
    Raw(String),
    Empty,
}

fn parse_line(line: &str) -> LineParsed {
    let clean = clean_ansi_and_symbols(line);
    if clean.is_empty() {
        return LineParsed::Empty;
    }

    if clean.starts_with("➤") {
        let cat = clean.trim_start_matches("➤").trim().to_string();
        return LineParsed::Category(cat);
    }

    if clean.starts_with("✓") {
        let text = clean.trim_start_matches("✓").trim().to_string();
        return LineParsed::Task {
            status: CleanStatus::Success,
            text,
        };
    }
    if clean.starts_with("•") {
        let text = clean.trim_start_matches("•").trim().to_string();
        return LineParsed::Task {
            status: CleanStatus::Success,
            text,
        };
    }
    if clean.starts_with("◎") {
        let text = clean.trim_start_matches("◎").trim().to_string();
        return LineParsed::Task {
            status: CleanStatus::Skipped,
            text,
        };
    }
    if clean.starts_with("☞") {
        let text = clean.trim_start_matches("☞").trim().to_string();
        return LineParsed::Task {
            status: CleanStatus::Info,
            text,
        };
    }
    if clean.starts_with("✗") {
        let text = clean.trim_start_matches("✗").trim().to_string();
        return LineParsed::Task {
            status: CleanStatus::Error,
            text,
        };
    }

    LineParsed::Raw(clean)
}

fn clean_ansi_and_symbols(s: &str) -> String {
    let mut result = String::new();
    let mut in_escape = false;
    for c in s.chars() {
        if c == '\x1b' {
            in_escape = true;
        } else if in_escape {
            if c.is_ascii_alphabetic() {
                in_escape = false;
            }
        } else {
            result.push(c);
        }
    }

    result.trim().to_string()
}

fn parse_bytes_from_detail(detail: &str) -> u64 {
    let parts: Vec<&str> = detail.split(|c: char| c == ',' || c.is_whitespace()).collect();
    for part in parts {
        let part_upper = part.to_uppercase();
        if part_upper.ends_with("GB") || part_upper.ends_with("MB") || part_upper.ends_with("KB") || part_upper.ends_with('B') {
            let num_str: String = part_upper.chars().filter(|&c| c.is_digit(10) || c == '.').collect();
            let val: f64 = num_str.parse().unwrap_or(0.0);
            if part_upper.ends_with("GB") {
                return (val * 1024.0 * 1024.0 * 1024.0) as u64;
            } else if part_upper.ends_with("MB") {
                return (val * 1024.0 * 1024.0) as u64;
            } else if part_upper.ends_with("KB") {
                return (val * 1024.0) as u64;
            } else if part_upper.ends_with('B') {
                return val as u64;
            }
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_menu_navigation() {
        let mut app = App::new();
        assert_eq!(app.current_screen, Screen::MainMenu);
        assert_eq!(app.menu_index, 0);

        // Test next_menu_item
        app.next_menu_item();
        assert_eq!(app.menu_index, 1);

        // Test wrapping around back to 0
        for _ in 0..4 {
            app.next_menu_item();
        }
        assert_eq!(app.menu_index, 0);

        // Test previous_menu_item wrapping
        app.previous_menu_item();
        assert_eq!(app.menu_index, 4);

        app.previous_menu_item();
        assert_eq!(app.menu_index, 3);
    }

    #[test]
    fn test_select_screen() {
        let mut app = App::new();
        app.menu_index = 1; // Uninstall
        app.select_current_menu_item();
        assert_eq!(app.current_screen, Screen::Uninstall);

        // Pressing back goes to MainMenu
        app.go_back();
        assert_eq!(app.current_screen, Screen::MainMenu);

        // Pressing back on MainMenu sets should_quit
        app.go_back();
        assert!(app.should_quit);
    }

    #[test]
    fn test_uninstall_search_and_toggle() {
        let mut app = App::new();
        app.uninstall_items = vec![
            UninstallItem {
                name: "Xcode.app".to_string(),
                size_mb: 32400,
                last_used: "2026-06-20".to_string(),
                selected: false,
            },
            UninstallItem {
                name: "Google Chrome.app".to_string(),
                size_mb: 1200,
                last_used: "2026-06-27".to_string(),
                selected: false,
            },
            UninstallItem {
                name: "Slack.app".to_string(),
                size_mb: 850,
                last_used: "2026-06-25".to_string(),
                selected: false,
            },
            UninstallItem {
                name: "Docker.app".to_string(),
                size_mb: 4500,
                last_used: "2026-06-15".to_string(),
                selected: false,
            },
            UninstallItem {
                name: "Visual Studio Code.app".to_string(),
                size_mb: 680,
                last_used: "2026-06-28".to_string(),
                selected: false,
            },
            UninstallItem {
                name: "Spotify.app".to_string(),
                size_mb: 320,
                last_used: "2026-06-10".to_string(),
                selected: false,
            },
            UninstallItem {
                name: "Steam.app".to_string(),
                size_mb: 12100,
                last_used: "2026-05-30".to_string(),
                selected: false,
            },
            UninstallItem {
                name: "Zoom.us.app".to_string(),
                size_mb: 450,
                last_used: "2026-06-22".to_string(),
                selected: false,
            },
        ];
        
        // Assert initial sizes
        assert_eq!(app.uninstall_items.len(), 8);
        assert_eq!(app.filtered_uninstall_items().len(), 8);
        
        // Filter search to "slack"
        app.uninstall_update_search("slack".to_string());
        assert_eq!(app.filtered_uninstall_items().len(), 1);
        assert_eq!(app.uninstall_index, 0);
        
        // Toggle selection (which should toggle Slack.app)
        app.uninstall_toggle();
        assert!(app.uninstall_items[2].selected); // Slack is at index 2
        
        // Clear search
        app.uninstall_update_search("".to_string());
        assert_eq!(app.filtered_uninstall_items().len(), 8);
        
        // Toggle again (Slack.app is selected, index 0 is Xcode)
        app.uninstall_toggle();
        assert!(app.uninstall_items[0].selected); // Xcode selected
        assert!(app.uninstall_items[2].selected); // Slack still selected
    }

    #[test]
    fn test_clean_line_parsing() {
        let mut app = App::new();
        app.clean_categories = initial_categories();
        app.active_category_idx = None;
        
        // Parse a category line
        app.parse_and_update_clean_line("➤ User essentials");
        assert_eq!(app.active_category_idx, Some(0));
        assert_eq!(app.clean_categories[0].tasks[0].status, CleanStatus::InProgress);
        
        // Parse a task success line
        app.parse_and_update_clean_line("  ✓ User app cache 154 items, 572.3MB");
        assert_eq!(app.clean_categories[0].tasks[0].status, CleanStatus::Success);
        assert_eq!(app.clean_categories[0].tasks[0].detail, "154 items, 572.3MB");
        assert_eq!(app.clean_categories[0].tasks[1].status, CleanStatus::InProgress); // next is InProgress
    }

    #[test]
    fn test_parse_bytes_from_detail() {
        assert_eq!(parse_bytes_from_detail("154 items, 572.3MB"), (572.3 * 1024.0 * 1024.0) as u64);
        assert_eq!(parse_bytes_from_detail("11 items, 644KB"), 644 * 1024);
        assert_eq!(parse_bytes_from_detail("already empty"), 0);
    }
}

pub fn is_root() -> bool {
    #[cfg(unix)]
    unsafe {
        libc::getuid() == 0
    }
    #[cfg(not(unix))]
    {
        false
    }
}

pub fn scan_applications() -> Vec<UninstallItem> {
    use std::fs;
    use std::time::SystemTime;

    let mut items = Vec::new();
    let scan_paths = vec!["/Applications"];

    for path in scan_paths {
        if let Ok(entries) = fs::read_dir(path) {
            for entry in entries.flatten() {
                let entry_path = entry.path();
                if entry_path.is_dir() && entry_path.extension().map_or(false, |ext| ext == "app") {
                    let name = entry_path.file_name().unwrap_or_default().to_string_lossy().to_string();
                    if name.starts_with('.') {
                        continue;
                    }

                    // Iterative directory size summation to prevent stack overflow
                    let mut size_bytes = 0;
                    let mut dir_stack = vec![entry_path.clone()];
                    let start_time = std::time::Instant::now();

                    while let Some(current_dir) = dir_stack.pop() {
                        // Max scan timeout per application directory to avoid lags on huge folders
                        if start_time.elapsed().as_millis() > 100 {
                            break;
                        }
                        if let Ok(read_entries) = fs::read_dir(&current_dir) {
                            for sub_entry in read_entries.flatten() {
                                if let Ok(meta) = sub_entry.metadata() {
                                    if meta.is_file() {
                                        size_bytes += meta.len();
                                    } else if meta.is_dir() {
                                        dir_stack.push(sub_entry.path());
                                    }
                                }
                            }
                        }
                    }

                    let size_mb = size_bytes / (1024 * 1024);
                    let last_used = if let Ok(metadata) = entry.metadata() {
                        let mtime = metadata.modified().unwrap_or(SystemTime::now());
                        format_system_time(mtime)
                    } else {
                        "Unknown".to_string()
                    };

                    items.push(UninstallItem {
                        name,
                        size_mb,
                        last_used,
                        selected: false,
                    });
                }
            }
        }
    }

    // Sort items by size descending
    items.sort_by(|a, b| b.size_mb.cmp(&a.size_mb));

    items
}

fn format_system_time(time: std::time::SystemTime) -> String {
    if let Ok(duration) = time.duration_since(std::time::SystemTime::UNIX_EPOCH) {
        let secs = duration.as_secs();
        let days = secs / 86400;
        let mut year = 1970;
        let mut day_count = days;
        loop {
            let is_leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
            let days_in_year = if is_leap { 366 } else { 365 };
            if day_count < days_in_year {
                break;
            }
            day_count -= days_in_year;
            year += 1;
        }

        let is_leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
        let month_days = if is_leap {
            vec![31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        } else {
            vec![31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        };

        let mut month = 1;
        for &days in &month_days {
            if day_count < days {
                break;
            }
            day_count -= days;
            month += 1;
        }

        format!("{:04}-{:02}-{:02}", year, month, day_count + 1)
    } else {
        "Unknown".to_string()
    }
}
