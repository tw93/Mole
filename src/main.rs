mod app;
mod screens;
mod scripts;
mod theme;
mod ui;

use app::{App, Screen};
use crossterm::event::{self, Event, KeyCode};
use std::time::Duration;
use tokio::sync::mpsc;

pub enum AppEvent {
    Key(crossterm::event::KeyEvent),
    Tick,
    Script(crate::scripts::ScriptEvent),
    UninstallScanComplete(Vec<crate::app::UninstallItem>),
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Setup panic hook to restore terminal state in case of panic
    let original_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |panic_info| {
        let _ = restore_terminal();
        original_hook(panic_info);
    }));

    // Setup terminal
    crossterm::terminal::enable_raw_mode()?;
    let mut stdout = std::io::stdout();
    crossterm::execute!(
        stdout,
        crossterm::terminal::EnterAlternateScreen,
        crossterm::cursor::Hide
    )?;
    
    let backend = ratatui::backend::CrosstermBackend::new(stdout);
    let mut terminal = ratatui::Terminal::new(backend)?;

    // Create unified event channel
    let (event_tx, event_rx) = mpsc::channel::<AppEvent>(256);

    // Spawn keypress event listener task
    let tx_keys = event_tx.clone();
    tokio::spawn(async move {
        loop {
            if let Ok(true) = event::poll(Duration::from_millis(500)) {
                if let Ok(Event::Key(key)) = event::read() {
                    if tx_keys.send(AppEvent::Key(key)).await.is_err() {
                        break; // Channel closed
                    }
                }
            }
        }
    });

    // Spawn Ctrl+C listener task
    let tx_ctrl_c = event_tx.clone();
    tokio::spawn(async move {
        loop {
            if tokio::signal::ctrl_c().await.is_ok() {
                let ctrl_c_key = crossterm::event::KeyEvent::new(
                    crossterm::event::KeyCode::Char('c'),
                    crossterm::event::KeyModifiers::CONTROL,
                );
                if tx_ctrl_c.send(AppEvent::Key(ctrl_c_key)).await.is_err() {
                    break;
                }
            }
        }
    });

    // Spawn Tick timer task (sending Tick events every 80ms)
    let tx_ticks = event_tx.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_millis(80));
        loop {
            interval.tick().await;
            if tx_ticks.send(AppEvent::Tick).await.is_err() {
                break;
            }
        }
    });

    // Spawn background application directory scanner
    let tx_scan = event_tx.clone();
    tokio::spawn(async move {
        let items = app::scan_applications();
        let _ = tx_scan.send(AppEvent::UninstallScanComplete(items)).await;
    });

    let mut app = App::new();
    let run_result = run_app(&mut terminal, &mut app, event_rx, event_tx.clone()).await;

    // Restore terminal
    restore_terminal()?;

    if let Err(err) = run_result {
        eprintln!("Application error: {:?}", err);
    }

    Ok(())
}

fn restore_terminal() -> std::io::Result<()> {
    crossterm::terminal::disable_raw_mode()?;
    crossterm::execute!(
        std::io::stdout(),
        crossterm::terminal::LeaveAlternateScreen,
        crossterm::cursor::Show
    )?;
    Ok(())
}

async fn run_app<B: ratatui::backend::Backend>(
    terminal: &mut ratatui::Terminal<B>,
    app: &mut App,
    mut event_rx: mpsc::Receiver<AppEvent>,
    event_tx: mpsc::Sender<AppEvent>,
) -> anyhow::Result<()> {
    // Draw initial state
    terminal.draw(|f| ui::draw(f, app))?;

    // Block on events arriving from the channel (reactively redrawing)
    'event_loop: while let Some(event) = event_rx.recv().await {
        if app.should_quit {
            break;
        }

        match event {
            AppEvent::Key(key) => {
                // 1. Cancel ongoing transitions and skip progress animations on keypress
                app.cancel_animations();

                // Ignore key release events to prevent double processing (primarily on Windows)
                if key.kind == event::KeyEventKind::Press {
                    // Intercept Ctrl+C
                    if key.code == KeyCode::Char('c') && key.modifiers.contains(crossterm::event::KeyModifiers::CONTROL) {
                        app.quit();
                        break 'event_loop;
                    }

                    // Handle dismissible global error first
                    if app.global_error.is_some() {
                        if key.code == KeyCode::Esc {
                            app.global_error = None;
                            terminal.draw(|f| ui::draw(f, app))?;
                            continue 'event_loop;
                        }
                    }

                    // Check if confirmation modal is open on Uninstall screen
                    if app.current_screen == Screen::Uninstall && app.uninstall_confirm_open {
                        match key.code {
                            KeyCode::Char('y') | KeyCode::Char('Y') | KeyCode::Enter => {
                                // Extract the selected application names to uninstall
                                let selected_names: Vec<String> = app.uninstall_items.iter()
                                    .filter(|i| i.selected)
                                    .map(|i| i.name.clone())
                                    .collect();

                                if !selected_names.is_empty() {
                                    app.uninstall_scanning_status = true;
                                    app.uninstall_confirm_open = false;
                                    app.go_back();

                                    let tx_scan = event_tx.clone();
                                    tokio::spawn(async move {
                                        let mut cmd = tokio::process::Command::new("bash");
                                        cmd.arg("bin/uninstall.sh");
                                        for name in &selected_names {
                                            cmd.arg(name);
                                        }
                                        cmd.stdin(std::process::Stdio::piped());
                                        cmd.stdout(std::process::Stdio::null());
                                        cmd.stderr(std::process::Stdio::null());

                                        if let Ok(mut child) = cmd.spawn() {
                                            if let Some(mut stdin) = child.stdin.take() {
                                                use tokio::io::AsyncWriteExt;
                                                let _ = stdin.write_all(b"y\n").await;
                                            }
                                            let _ = child.wait().await;
                                        }

                                        // Rescan Applications directory to refresh real status
                                        let items = app::scan_applications();
                                        let _ = tx_scan.send(AppEvent::UninstallScanComplete(items)).await;
                                    });
                                } else {
                                    app.uninstall_confirm_open = false;
                                }
                            }
                            KeyCode::Char('n') | KeyCode::Char('N') | KeyCode::Esc => {
                                app.uninstall_confirm_open = false;
                            }
                            _ => {}
                        }
                    } else if app.current_screen == Screen::Uninstall && app.uninstall_searching {
                        match key.code {
                            KeyCode::Esc | KeyCode::Enter => {
                                app.uninstall_searching = false;
                            }
                            KeyCode::Backspace => {
                                let mut q = app.uninstall_search.clone();
                                q.pop();
                                app.uninstall_update_search(q);
                            }
                            KeyCode::Char(c) => {
                                let mut q = app.uninstall_search.clone();
                                q.push(c);
                                app.uninstall_update_search(q);
                            }
                            _ => {}
                        }
                    } else {
                        match (app.current_screen, key.code) {
                            // Universal exit / back behavior
                            (_, KeyCode::Char('q') | KeyCode::Char('Q')) => {
                                match app.current_screen {
                                    Screen::MainMenu => app.quit(),
                                    _ => app.go_back(),
                                }
                            }
                            (_, KeyCode::Esc) => {
                                app.go_back();
                            }
                            // Main Menu Navigation
                            (Screen::MainMenu, KeyCode::Up) => {
                                app.previous_menu_item();
                            }
                            (Screen::MainMenu, KeyCode::Down) => {
                                app.next_menu_item();
                            }
                            (Screen::MainMenu, KeyCode::Enter) => {
                                app.select_current_menu_item();
                                match app.current_screen {
                                    Screen::Optimize => {
                                        let _ = run_sub_tui("bin/optimize.sh");
                                        app.current_screen = Screen::MainMenu;
                                    }
                                    Screen::Analyze => {
                                        let _ = run_sub_tui("bin/analyze-go");
                                        app.current_screen = Screen::MainMenu;
                                    }
                                    Screen::Status => {
                                        let _ = run_sub_tui("bin/status-go");
                                        app.current_screen = Screen::MainMenu;
                                    }
                                    _ => {}
                                }
                            }
                            // Uninstall Navigation
                            (Screen::Uninstall, KeyCode::Up) => {
                                app.uninstall_prev();
                            }
                            (Screen::Uninstall, KeyCode::Down) => {
                                app.uninstall_next();
                            }
                            (Screen::Uninstall, KeyCode::Char(' ')) => {
                                app.uninstall_toggle();
                            }
                            (Screen::Uninstall, KeyCode::Char('/')) => {
                                app.uninstall_searching = true;
                            }
                            (Screen::Uninstall, KeyCode::Enter) => {
                                // Only open confirm modal if there is at least one item selected
                                if app.uninstall_items.iter().any(|i| i.selected) {
                                    app.uninstall_confirm_open = true;
                                } else {
                                    app.go_back();
                                }
                            }
                            // Clean Navigation
                            (Screen::Clean, KeyCode::Enter) => {
                                app.start_clean_execution(event_tx.clone());
                            }
                            _ => {}
                        }
                    }
                }
            }
            AppEvent::Tick => {
                app.handle_tick();
            }
            AppEvent::Script(script_event) => {
                // If script errors with custom user-friendly message, we can populate it in clean_error
                // Or set global_error if it fails abruptly
                app.handle_clean_event(script_event);
            }
            AppEvent::UninstallScanComplete(items) => {
                app.uninstall_items = items;
                app.uninstall_scanning_status = false;
            }
        }

        // Draw terminal screen on state change
        terminal.draw(|f| ui::draw(f, app))?;
    }

    Ok(())
}

fn run_sub_tui(cmd_name: &str) -> anyhow::Result<()> {
    // 1. Temporarily restore terminal raw mode and show cursor
    crossterm::terminal::disable_raw_mode()?;
    crossterm::execute!(
        std::io::stdout(),
        crossterm::terminal::LeaveAlternateScreen,
        crossterm::cursor::Show
    )?;

    // 2. Resolve command path or execute package directly via Go
    let has_binary = std::path::Path::new(cmd_name).exists();
    let mut cmd = if has_binary {
        std::process::Command::new(cmd_name)
    } else {
        let package_path = if cmd_name.contains("analyze") {
            "cmd/analyze/main.go"
        } else if cmd_name.contains("status") {
            "cmd/status/main.go"
        } else {
            ""
        };

        if !package_path.is_empty() {
            let mut c = std::process::Command::new("go");
            c.arg("run");
            c.arg(package_path);
            c
        } else {
            let mut c = std::process::Command::new("bash");
            c.arg(cmd_name);
            c
        }
    };

    let mut child = cmd
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .spawn()?;
    let _ = child.wait()?;

    // 3. Re-initialize raw mode and return focus
    crossterm::terminal::enable_raw_mode()?;
    crossterm::execute!(
        std::io::stdout(),
        crossterm::terminal::EnterAlternateScreen,
        crossterm::cursor::Hide
    )?;

    Ok(())
}
