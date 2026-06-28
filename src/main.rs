mod app;
mod screens;
mod scripts;
mod theme;
mod ui;

use app::{App, Screen};
use crossterm::event::{self, Event, KeyCode};
use std::time::Duration;
use tokio::sync::mpsc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

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

    // Shared suspension state for running subprocesses
    let is_suspended = Arc::new(AtomicBool::new(false));

    // Spawn keypress event listener task
    let tx_keys = event_tx.clone();
    let is_suspended_keys = is_suspended.clone();
    tokio::spawn(async move {
        loop {
            if is_suspended_keys.load(Ordering::SeqCst) {
                tokio::time::sleep(Duration::from_millis(50)).await;
                continue;
            }
            if let Ok(true) = event::poll(Duration::from_millis(100)) {
                if is_suspended_keys.load(Ordering::SeqCst) {
                    continue;
                }
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
    let is_suspended_ctrl = is_suspended.clone();
    tokio::spawn(async move {
        loop {
            if is_suspended_ctrl.load(Ordering::SeqCst) {
                tokio::time::sleep(Duration::from_millis(50)).await;
                continue;
            }
            if tokio::signal::ctrl_c().await.is_ok() {
                if is_suspended_ctrl.load(Ordering::SeqCst) {
                    continue;
                }
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
    let run_result = run_app(&mut terminal, &mut app, event_rx, event_tx.clone(), is_suspended.clone()).await;

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
    is_suspended: Arc<AtomicBool>,
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
                                 // Extract the selected application names to uninstall, stripping the '.app' suffix
                                 // to match the exact pattern matchers of bin/uninstall.sh
                                 let selected_names: Vec<String> = app.uninstall_items.iter()
                                     .filter(|i| i.selected)
                                     .map(|i| {
                                         if i.name.ends_with(".app") {
                                             i.name[..i.name.len() - 4].to_string()
                                         } else {
                                             i.name.clone()
                                         }
                                     })
                                     .collect();

                                 if !selected_names.is_empty() {
                                     app.uninstall_scanning_status = true;
                                     app.uninstall_confirm_open = false;
                                     app.go_back();

                                     // Execute real uninstall with auto-confirmation for script prompts
                                     let _ = run_sub_tui_impl("bin/uninstall.sh", &selected_names, &is_suspended, true);
                                     let _ = terminal.clear(); // Clear the Ratatui cached view to redraw correctly

                                     let tx_scan = event_tx.clone();
                                     tokio::spawn(async move {
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
                                         let _ = run_sub_tui_impl("bin/optimize.sh", &[], &is_suspended, false);
                                         let _ = terminal.clear();
                                         app.current_screen = Screen::MainMenu;
                                     }
                                     Screen::Analyze => {
                                         let _ = run_sub_tui_impl("bin/analyze-go", &[], &is_suspended, false);
                                         let _ = terminal.clear();
                                         app.current_screen = Screen::MainMenu;
                                     }
                                     Screen::Status => {
                                         let _ = run_sub_tui_impl("bin/status-go", &[], &is_suspended, false);
                                         let _ = terminal.clear();
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

fn run_sub_tui_impl(
    cmd_name: &str,
    extra_args: &[String],
    is_suspended: &Arc<AtomicBool>,
    auto_confirm: bool,
) -> anyhow::Result<()> {
    // 1. Suspend the background event listener loops
    is_suspended.store(true, Ordering::SeqCst);

    // Wait briefly for raw state events to settle
    std::thread::sleep(Duration::from_millis(150));

    // 2. Temporarily disable TUI raw mode and return terminal screens
    crossterm::terminal::disable_raw_mode()?;
    crossterm::execute!(
        std::io::stdout(),
        crossterm::terminal::LeaveAlternateScreen,
        crossterm::cursor::Show
    )?;

    // 3. Resolve the execution target path
    let has_binary = std::path::Path::new(cmd_name).exists();
    let mut cmd = if has_binary {
        let mut c = std::process::Command::new(cmd_name);
        for arg in extra_args {
            c.arg(arg);
        }
        c
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
            for arg in extra_args {
                c.arg(arg);
            }
            c
        } else {
            let mut c = std::process::Command::new("bash");
            c.arg(cmd_name);
            for arg in extra_args {
                c.arg(arg);
            }
            c
        }
    };

    // Configure stdin based on auto-confirm requirements
    if auto_confirm {
        cmd.stdin(std::process::Stdio::piped());
    } else {
        cmd.stdin(std::process::Stdio::inherit());
    }
    cmd.stdout(std::process::Stdio::inherit());
    cmd.stderr(std::process::Stdio::inherit());

    // Run subprocess
    let mut child = cmd.spawn()?;

    // Auto-feed confirm inputs to stdin if running with auto_confirm
    if auto_confirm {
        if let Some(mut stdin) = child.stdin.take() {
            use std::io::Write;
            let _ = stdin.write_all(b"y\n\n");
        }
    }

    let _ = child.wait()?;

    // 4. Restore TUI raw mode and return alternate screen views
    crossterm::terminal::enable_raw_mode()?;
    crossterm::execute!(
        std::io::stdout(),
        crossterm::terminal::EnterAlternateScreen,
        crossterm::cursor::Hide
    )?;

    // 5. Resume background loops
    is_suspended.store(false, Ordering::SeqCst);

    Ok(())
}
