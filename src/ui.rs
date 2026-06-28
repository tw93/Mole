use crate::app::{App, Screen};
use crate::theme;
use ratatui::{
    layout::{Constraint, Direction, Layout, Alignment},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, BorderType, Borders, List, ListItem, Paragraph},
    Frame,
};

pub fn draw(frame: &mut Frame, app: &App) {
    // Base background layout
    let main_block = Block::default()
        .style(Style::default().bg(theme::COLOR_DARK_BG).fg(Color::White));
    frame.render_widget(main_block, frame.area());

    // 0. Handle Global Error Banner
    let (error_area, content_area) = if let Some(ref _err) = app.global_error {
        let splits = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Length(3), // Error banner
                Constraint::Min(0),    // Main content
            ])
            .split(frame.area());
        (Some(splits[0]), splits[1])
    } else {
        (None, frame.area())
    };

    if let Some(err_area) = error_area {
        let err_block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .style(Style::default().fg(Color::Red).bg(Color::Rgb(50, 10, 10)));
            
        let err_text = app.global_error.as_deref().unwrap_or("Unknown error");
        let error_paragraph = Paragraph::new(Line::from(vec![
            Span::styled(" 🚨 ERROR: ", Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)),
            Span::styled(err_text, Style::default().fg(Color::White)),
            Span::styled(" (Press Esc to dismiss) ", theme::STYLE_MUTED),
        ]))
        .block(err_block)
        .alignment(Alignment::Center);
        
        frame.render_widget(error_paragraph, err_area);
    }

    // Define layouts dynamically depending on the current screen
    let chunks = match app.current_screen {
        Screen::MainMenu => {
            // Main menu has space for the ASCII art banner
            Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Length(7), // Header with ASCII art
                    Constraint::Min(5),    // Main content (List)
                    Constraint::Length(3), // Footer / Status bar
                ])
                .split(content_area)
        }
        _ => {
            // Sub-screens bypass the ASCII art header to save workspace space
            Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Min(5),    // Main content (Paragraph)
                    Constraint::Length(3), // Footer / Status bar
                ])
                .split(content_area)
        }
    };

    // 1. Draw Header (Only on MainMenu)
    if app.current_screen == Screen::MainMenu {
        let ascii_art = vec![
            r#" ██████╗██╗     ███████╗ ██████╗     ███╗   ███╗ ██████╗ ██╗     ███████╗ "#,
            r#"██╔════╝██║     ██╔════╝██╔═══██╗    ████╗ ████║██╔═══██╗██║     ██╔════╝ "#,
            r#"██║     ██║     █████╗  ██║   ██║    ██╔████╔██║██║   ██║██║     █████╗   "#,
            r#"██║     ██║     ██╔══╝  ██║   ██║    ██║╚██╔╝██║██║   ██║██║     ██╔══╝   "#,
            r#"╚██████╗███████╗███████╗╚██████╔╝    ██║ ╚═╝ ██║╚██████╔╝███████╗███████╗ "#,
            r#" ╚═════╝╚══════╝╚══════╝ ╚═════╝     ╚═╝     ╚═╝ ╚═════╝ ╚══════╝╚══════╝ "#,
        ];

        let header_text: Vec<Line> = ascii_art
            .iter()
            .map(|line| Line::from(Span::styled(*line, theme::STYLE_HEADER)))
            .collect();

        let header_widget = Paragraph::new(header_text)
            .alignment(Alignment::Center);
        frame.render_widget(header_widget, chunks[0]);
    }

    // 2. Draw Content based on active screen
    match app.current_screen {
        Screen::MainMenu => {
            // Main menu list items
            let items: Vec<ListItem> = Screen::menu_items()
                .iter()
                .enumerate()
                .map(|(i, screen)| {
                    let name = screen.display_name();
                    let is_active = i == app.menu_index;
                    let is_prev = app.menu_prev_index == Some(i) && app.menu_transition_ticks > 0;

                    if is_active {
                        let text = Line::from(vec![
                            Span::styled("  ❯  ", theme::STYLE_SELECTED),
                            Span::styled(name.to_string(), theme::STYLE_SELECTED),
                        ]);
                        ListItem::new(text).style(Style::default().bg(Color::Rgb(40, 44, 52)))
                    } else if is_prev {
                        let text = Line::from(vec![
                            Span::styled("  ›  ", theme::STYLE_MUTED),
                            Span::styled(name.to_string(), theme::STYLE_MUTED),
                        ]);
                        ListItem::new(text).style(Style::default().bg(Color::Rgb(33, 37, 43)))
                    } else {
                        let text = Line::from(vec![
                            Span::styled("     ", Style::default().fg(Color::White)),
                            Span::styled(name.to_string(), Style::default().fg(Color::White)),
                        ]);
                        ListItem::new(text)
                    }
                })
                .collect();

            // Center the list horizontally
            let list_layout = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([
                    Constraint::Percentage(25),
                    Constraint::Percentage(50),
                    Constraint::Percentage(25),
                ])
                .split(chunks[1]);

            let menu_list = List::new(items)
                .block(
                    Block::default()
                        .borders(Borders::ALL)
                        .border_type(BorderType::Rounded)
                        .border_style(Style::default().fg(theme::COLOR_CYAN))
                        .title(" Navigation Options ")
                        .title_alignment(Alignment::Center)
                        .title_style(theme::STYLE_HEADER)
                        .padding(ratatui::widgets::Padding::uniform(1))
                );

            frame.render_widget(menu_list, list_layout[1]);
        }
        Screen::Clean => {
            crate::screens::clean::draw(frame, app, chunks[0]);
        }
        Screen::Uninstall => {
            crate::screens::uninstall::draw(frame, app, chunks[0]);
        }
        screen => {
            // Placeholder screen for sub-views
            let sub_layout = Layout::default()
                .direction(Direction::Horizontal)
                .constraints([
                    Constraint::Percentage(10),
                    Constraint::Percentage(80),
                    Constraint::Percentage(10),
                ])
                .split(chunks[0]);

            let content_text = vec![
                Line::from(vec![
                    Span::raw("Welcome to the "),
                    Span::styled(screen.display_name(), theme::STYLE_HEADER),
                    Span::raw(" module."),
                ]),
                Line::from(""),
                Line::from(Span::styled("No real logic is connected yet.", theme::STYLE_SELECTED)),
                Line::from(""),
                Line::from(Span::styled(
                    "Press Esc or Q to return to the Main Menu.",
                    theme::STYLE_MUTED
                )),
            ];

            let content_widget = Paragraph::new(content_text)
                .alignment(Alignment::Center)
                .block(
                    Block::default()
                        .borders(Borders::ALL)
                        .border_type(BorderType::Rounded)
                        .border_style(Style::default().fg(theme::COLOR_PURPLE))
                        .title(format!(" {} ", screen.display_name()))
                        .title_alignment(Alignment::Center)
                        .title_style(theme::STYLE_HEADER)
                        .padding(ratatui::widgets::Padding::uniform(2))
                );

            frame.render_widget(content_widget, sub_layout[1]);
        }
    }

    // 3. Draw Footer / Status Bar (context-sensitive, persistent at the bottom)
    let status_keys = match app.current_screen {
        Screen::MainMenu => vec![
            Span::styled(" ▲/▼ ", theme::STYLE_HEADER.bg(Color::Rgb(40, 44, 52))),
            Span::raw(" Navigate  "),
            Span::styled(" Enter ", theme::STYLE_SUCCESS.bg(Color::Rgb(40, 44, 52))),
            Span::raw(" Confirm  "),
            Span::styled(" Q ", Style::default().fg(Color::Red).bg(Color::Rgb(40, 44, 52)).add_modifier(Modifier::BOLD)),
            Span::raw(" Quit  "),
        ],
        Screen::Uninstall => {
            if app.uninstall_searching {
                vec![
                    Span::styled(" Esc/Enter ", theme::STYLE_HEADER.bg(Color::Rgb(40, 44, 52))),
                    Span::raw(" Exit Search  "),
                    Span::styled(" Backspace ", theme::STYLE_MUTED.bg(Color::Rgb(40, 44, 52))),
                    Span::raw(" Delete  "),
                    Span::styled(" Keys ", theme::STYLE_SELECTED.bg(Color::Rgb(40, 44, 52))),
                    Span::raw(" Filter list "),
                ]
            } else {
                vec![
                    Span::styled(" ▲/▼ ", theme::STYLE_HEADER.bg(Color::Rgb(40, 44, 52))),
                    Span::raw(" Navigate  "),
                    Span::styled(" Space ", theme::STYLE_SELECTED.bg(Color::Rgb(40, 44, 52))),
                    Span::raw(" Toggle Selection  "),
                    Span::styled(" / ", theme::STYLE_HEADER.bg(Color::Rgb(40, 44, 52))),
                    Span::raw(" Search  "),
                    Span::styled(" Enter ", theme::STYLE_SUCCESS.bg(Color::Rgb(40, 44, 52))),
                    Span::raw(" Confirm Uninstall  "),
                    Span::styled(" Esc/Q ", Style::default().fg(Color::Red).bg(Color::Rgb(40, 44, 52)).add_modifier(Modifier::BOLD)),
                    Span::raw(" Back  "),
                ]
            }
        }
        Screen::Clean => {
            if app.clean_running {
                vec![
                    Span::styled(" Esc/Q ", Style::default().fg(Color::Red).bg(Color::Rgb(40, 44, 52)).add_modifier(Modifier::BOLD)),
                    Span::raw(" Back to Menu (Clean running in background) "),
                ]
            } else {
                vec![
                    Span::styled(" Enter ", theme::STYLE_SUCCESS.bg(Color::Rgb(40, 44, 52))),
                    Span::raw(" Run clean.sh  "),
                    Span::styled(" Esc/Q ", Style::default().fg(Color::Red).bg(Color::Rgb(40, 44, 52)).add_modifier(Modifier::BOLD)),
                    Span::raw(" Back  "),
                ]
            }
        }
        _ => vec![
            Span::styled(" Esc/Q ", theme::STYLE_HEADER.bg(Color::Rgb(40, 44, 52))),
            Span::raw(" Back to Menu  "),
        ],
    };

    let status_line = Line::from(status_keys);
    let footer_widget = Paragraph::new(status_line)
        .alignment(Alignment::Center)
        .block(
            Block::default()
                .borders(Borders::ALL)
                .border_type(BorderType::Rounded)
                .border_style(theme::STYLE_MUTED)
                .padding(ratatui::widgets::Padding::horizontal(1))
        );

    let footer_chunk = match app.current_screen {
        Screen::MainMenu => chunks[2],
        _ => chunks[1],
    };
    frame.render_widget(footer_widget, footer_chunk);
}
