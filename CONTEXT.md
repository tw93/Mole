Project: Mole — a Mac system cleaner TUI
Language: Rust (edition 2021)
TUI framework: Ratatui + crossterm backend
Async runtime: Tokio
Shell integration: existing bash scripts in /scripts — call via tokio::process::Command, stream stdout

Screens:
- Main menu (5 options: Clean, Uninstall, Optimize, Analyze, Status)
- Clean: live streaming output of bash script execution, grouped by category
- Uninstall: scrollable multi-select list with app name, size, last used date
- Optimize, Analyze, Status: TBD

Design:
- Color palette: purple (#C678DD) for headers/selected, green (#98C379) for success, 
  cyan (#56B6C2) for highlights, white for body, dark bg (#1E1E2E)
- Borders: rounded corners everywhere
- Status bar at bottom with keybindings
- ASCII art header on main menu

Architecture:
- app.rs: App state struct, screen enum, event loop
- ui.rs: all rendering functions
- scripts.rs: shell command execution, stdout streaming
- Each screen gets its own file under src/screens/

Keybindings: arrows navigate, Space selects, Enter confirms, Q quits, / for search