use super::{
    format, logo,
    state::{Chain, Eta, Messages, State, TuiMessage},
};
use ratatui::{
    style::{Color, Style, Stylize},
    text::{Line, Span},
};
use unicode_width::UnicodeWidthChar;

const SPINNER: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
pub const SPINNER_INTERVAL_MS: u64 = 80;

#[derive(Clone, Copy, Debug)]
pub struct Palette {
    pub truecolor: bool,
}

impl Palette {
    pub fn rgb(self, (r, g, b): (u8, u8, u8)) -> Color {
        if self.truecolor {
            Color::Rgb(r, g, b)
        } else {
            Color::Indexed(ansi256(r, g, b))
        }
    }
    fn primary(self) -> Color {
        self.rgb((0x98, 0x60, 0xE5))
    }
    fn secondary(self) -> Color {
        self.rgb((0xFF, 0xBB, 0x2F))
    }
    fn info(self) -> Color {
        self.rgb((0x6C, 0xBF, 0xEE))
    }
    fn danger(self) -> Color {
        self.rgb((0xFF, 0x82, 0x69))
    }
    fn success(self) -> Color {
        self.rgb((0x3B, 0x8C, 0x3D))
    }
    fn named(self, name: &str) -> Color {
        match name {
            "primary" => self.primary(),
            "secondary" => self.secondary(),
            "info" => self.info(),
            "danger" => self.danger(),
            "success" => self.success(),
            "gray" => GRAY,
            _ => WHITE,
        }
    }
}

// The 16-colour "white" and "gray" (bright black) the display has always used,
// so they follow the terminal's theme.
const WHITE: Color = Color::Gray;
const GRAY: Color = Color::DarkGray;

/// The xterm 256-colour cube, for terminals that don't advertise truecolor.
fn ansi256(r: u8, g: u8, b: u8) -> u8 {
    if r == g && g == b {
        return match r {
            0..=7 => 16,
            249..=255 => 231,
            _ => ((r as f64 - 8.) / 247. * 24.).round() as u8 + 232,
        };
    }
    let level = |c: u8| (c as f64 / 255. * 5.).round() as u8;
    16 + 36 * level(r) + 6 * level(g) + level(b)
}

fn progress_bar(
    palette: Palette,
    loaded: i64,
    buffered: i64,
    out_of: i64,
    width: usize,
) -> Vec<Span<'static>> {
    let fraction = |count: i64| {
        if out_of > 0 {
            (count as f64 / out_of as f64).max(0.)
        } else {
            0.
        }
    };
    let cells = |fraction: f64| ((width as f64 * fraction).floor() as usize).min(width);
    let label = format!("{}% ", (fraction(loaded) * 100.).trunc() as i64);
    let loaded_cells = cells(fraction(loaded)).max(label.len());
    let buffered_cells = cells(fraction(buffered)).max(loaded_cells);
    vec![
        Span::styled(
            format!("{label:>loaded_cells$}"),
            Style::new().fg(GRAY).bg(palette.secondary()),
        ),
        Span::styled(
            " ".repeat(buffered_cells - loaded_cells),
            Style::new().bg(GRAY),
        ),
        Span::styled(
            " ".repeat(width.saturating_sub(buffered_cells)),
            Style::new().bg(WHITE),
        ),
    ]
}

fn chain_lines(
    palette: Palette,
    chain: &Chain,
    block_unit: &str,
    header_width: usize,
    chains_width: usize,
) -> Vec<Line<'static>> {
    let mut header = vec![
        Span::raw("Chain: "),
        Span::raw(chain.chain_id.clone()).bold(),
        Span::raw(" "),
    ];
    if chain.powered_by_hyper_sync {
        header.push(Span::styled("⚡", Style::new().fg(palette.secondary())));
    }
    let header_used: usize = header.iter().map(|span| span.width()).sum();
    header.push(Span::raw(
        " ".repeat(header_width.saturating_sub(header_used)),
    ));
    header.extend(progress_bar(
        palette,
        chain.progress_block - chain.start_block,
        chain.buffer_block - chain.start_block,
        chain.to_block - chain.start_block,
        chains_width.saturating_sub(header_width),
    ));

    let end_label = if chain.end_block.is_some() {
        format!(" (End {block_unit})")
    } else {
        String::new()
    };
    let blocks = format!(
        "{block_unit}s: {} / {}{end_label}  ",
        format::number(chain.progress_block as f64),
        format::number(chain.to_block as f64),
    );
    let events = format!("Events: {}", format::number(chain.events_processed));
    let gray = Style::new().fg(GRAY);
    let mut lines = vec![Line::from(header)];
    if blocks.len() + events.len() <= chains_width {
        lines.push(Line::from(vec![
            Span::styled(blocks, gray),
            Span::styled(events, gray),
        ]));
    } else {
        lines.push(Line::styled(blocks, gray));
        lines.push(Line::styled(events, gray));
    }
    lines.push(Line::default());
    lines
}

fn link(label: &str, url: &str, palette: Palette) -> Vec<Span<'static>> {
    vec![
        Span::raw(format!("{label}: ")),
        Span::styled(
            url.to_string(),
            Style::new().fg(palette.info()).underlined(),
        ),
    ]
}

fn message_line(palette: Palette, message: &TuiMessage) -> Line<'static> {
    Line::styled(
        message.content.clone(),
        Style::new().fg(palette.named(&message.color)),
    )
}

/// The frame at most `height` rows tall: the logo goes first when the status
/// alone is what fits.
pub fn frame(
    state: &State,
    now: f64,
    tick: usize,
    width: u16,
    height: u16,
    palette: Palette,
) -> Vec<Line<'static>> {
    let (width, height) = (width as usize, height as usize);
    let rgb = |color| palette.rgb(color);
    let status = wrap(status(state, now, tick, width, palette), width);
    let mut logo = if width >= logo::width() {
        logo::lines(rgb)
    } else {
        vec![logo::compact(rgb)]
    };
    logo.push(Line::default());
    let mut lines = if logo.len() + status.len() <= height {
        [logo, status].concat()
    } else {
        status
    };
    lines.truncate(height);
    lines
}

fn status(
    state: &State,
    now: f64,
    tick: usize,
    width: usize,
    palette: Palette,
) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    let chains_width = width.saturating_sub(2).min(60);
    let header_width = state
        .chains
        .iter()
        .map(|chain| chain.chain_id.len())
        .max()
        .unwrap_or(0)
        + 10;
    for chain in &state.chains {
        lines.extend(chain_lines(
            palette,
            chain,
            &state.info.block_unit,
            header_width,
            chains_width,
        ));
    }

    let synced = state.is_fully_synced();
    let mut total = vec![
        Span::raw("Total Events: ").bold(),
        Span::styled(
            format::number(state.total_events()),
            Style::new().fg(palette.secondary()),
        ),
    ];
    if let (false, Some(eps)) = (synced, state.events_per_second()) {
        total.push(Span::styled(
            format!(" ({} events/sec)", format::number(eps)),
            Style::new().fg(GRAY),
        ));
    }
    lines.push(Line::from(total));

    let spinner = Span::styled(
        SPINNER[tick % SPINNER.len()],
        Style::new().fg(palette.primary()),
    );
    lines.push(match state.eta(now) {
        Eta::Synced(distance) => Line::from(vec![
            Span::raw(format!("Time Synced: {distance} (")),
            Span::styled("synced", Style::new().fg(palette.success())),
            Span::raw(")"),
        ])
        .bold(),
        Eta::Syncing(eta) => Line::from(vec![
            Span::raw(format!("Sync Time ETA: {eta} (")),
            spinner,
            Span::styled(" in progress", Style::new().fg(palette.secondary())),
            Span::raw(")"),
        ])
        .bold(),
        Eta::Calculating => Line::from(vec![spinner, Span::raw(" Calculating ETA...").bold()]),
    });

    if let Some((time_ms, reset_in_ms)) = state.rate_limit() {
        let danger = Style::new().fg(palette.danger());
        let reset = if reset_in_ms > 0. {
            format!(
                " (⏳ {}s until reset)",
                format::number((reset_in_ms / 1000.).ceil().max(1.))
            )
        } else {
            String::new()
        };
        lines.push(Line::default());
        lines.push(Line::styled(
            format!(
                "Backfill {}s slower due to your plan's rate limit{reset}",
                format::number(time_ms / 1000.)
            ),
            danger,
        ));
        lines.push(Line::from(vec![
            Span::styled("Upgrade at ", danger),
            Span::styled("https://envio.dev/app/api-tokens", danger.underlined()),
            Span::styled(" for higher rate limits.", danger),
        ]));
    }

    lines.push(Line::default());
    let info = &state.info;
    let mut graphql = link("GraphQL", &info.graphql_url, palette);
    if let Some(password) = &info.graphql_password {
        graphql.push(Span::styled(
            format!(" (password: {password})"),
            Style::new().fg(GRAY),
        ));
    }
    lines.push(Line::from(graphql));
    if let Some(url) = &info.dev_console_url {
        lines.push(Line::from(link("Dev Console", url, palette)));
    }
    if let Some(url) = &info.clickhouse_url {
        lines.push(Line::from(link("ClickHouse", url, palette)));
    }

    let notifications = match &state.messages {
        Messages::Loading => vec![],
        Messages::Loaded(messages) => messages
            .iter()
            .map(|message| message_line(palette, message))
            .collect(),
        Messages::Failed => vec![message_line(
            palette,
            &TuiMessage {
                color: "danger".to_string(),
                content: "Failed to load messages from envio server".to_string(),
            },
        )],
    };
    if !notifications.is_empty() {
        lines.push(Line::default());
        lines.push(Line::raw("Notifications:").bold());
        lines.extend(notifications);
    }
    lines
}

/// Breaks lines at the terminal width, so the line count is the height the
/// text occupies on screen.
pub fn wrap(lines: Vec<Line<'static>>, width: usize) -> Vec<Line<'static>> {
    let width = width.max(1);
    let mut out = Vec::with_capacity(lines.len());
    for line in lines {
        let line_style = line.style;
        let mut row: Vec<Span<'static>> = Vec::new();
        let mut used = 0;
        for span in line.spans {
            let mut text = String::new();
            for c in span.content.chars() {
                let c_width = c.width().unwrap_or(0);
                if used + c_width > width && used > 0 {
                    if !text.is_empty() {
                        row.push(Span::styled(std::mem::take(&mut text), span.style));
                    }
                    out.push(Line::from(std::mem::take(&mut row)).style(line_style));
                    used = 0;
                }
                text.push(c);
                used += c_width;
            }
            if !text.is_empty() {
                row.push(Span::styled(text, span.style));
            }
        }
        out.push(Line::from(row).style(line_style));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tui::state::{TuiChain, TuiInfo};
    use ratatui::{backend::TestBackend, widgets::Paragraph, Terminal};

    const NOW: f64 = 1_700_000_100_000.;
    const START: f64 = 1_700_000_000_000.;

    fn info() -> TuiInfo {
        TuiInfo {
            block_unit: "Block".to_string(),
            start_time: START,
            graphql_url: "http://localhost:8080".to_string(),
            graphql_password: Some("testing".to_string()),
            dev_console_url: None,
            clickhouse_url: None,
        }
    }

    fn syncing(chain_id: &str) -> TuiChain {
        TuiChain {
            chain_id: chain_id.to_string(),
            powered_by_hyper_sync: true,
            start_block: 1_000_000,
            end_block: None,
            first_event_block_number: Some(1_000_000),
            progress_block_number: 1_250_000,
            latest_fetched_block_number: 1_500_000,
            known_height: 2_000_000,
            source_block_number: 2_000_000,
            timestamp_caught_up_to_head_or_endblock: None,
            num_events_processed: 123_456.,
            rate_limit_time_ms: 0.,
            rate_limit_reset_in_ms: None,
        }
    }

    fn synced(chain_id: &str) -> TuiChain {
        TuiChain {
            end_block: Some(2_000_000),
            progress_block_number: 2_000_000,
            latest_fetched_block_number: 2_000_000,
            timestamp_caught_up_to_head_or_endblock: Some(START + 95_000.),
            ..syncing(chain_id)
        }
    }

    fn state(chains: &[TuiChain], messages: Messages) -> State {
        let mut state = State::new(info());
        state.update(chains, NOW - 10_000.);
        let advanced: Vec<TuiChain> = chains
            .iter()
            .map(|chain| TuiChain {
                num_events_processed: chain.num_events_processed + 50_000.,
                ..chain.clone()
            })
            .collect();
        state.update(&advanced, NOW);
        state.messages = messages;
        state
    }

    /// The rendered screen, one row per line, with a style legend wherever
    /// styling starts, the way insta's buffer snapshots read.
    fn render(state: &State, width: u16) -> String {
        let lines = wrap(
            status(state, NOW, 3, width as usize, Palette { truecolor: true }),
            width as usize,
        );
        let mut terminal = Terminal::new(TestBackend::new(width, lines.len() as u16)).unwrap();
        terminal
            .draw(|f| f.render_widget(Paragraph::new(lines), f.area()))
            .unwrap();
        format!("{:?}", terminal.backend().buffer())
    }

    #[test]
    fn renders_a_syncing_chain() {
        insta::assert_snapshot!(render(&state(&[syncing("1")], Messages::Loading), 100));
    }

    #[test]
    fn renders_synced_chains_with_links_and_notifications() {
        let mut state = state(
            &[synced("1"), synced("8453")],
            Messages::Loaded(vec![TuiMessage {
                color: "info".to_string(),
                content: "A new envio version is available".to_string(),
            }]),
        );
        state.info.dev_console_url = Some("https://envio.dev/console".to_string());
        state.info.clickhouse_url = Some("http://localhost:8123/play".to_string());
        insta::assert_snapshot!(render(&state, 100));
    }

    #[test]
    fn renders_a_rate_limited_run_and_a_failed_message_load() {
        let limited = TuiChain {
            rate_limit_time_ms: 12_400.,
            rate_limit_reset_in_ms: Some(2_100.),
            ..syncing("1")
        };
        insta::assert_snapshot!(render(&state(&[limited], Messages::Failed), 100));
    }

    #[test]
    fn moves_events_to_their_own_row_on_a_narrow_terminal() {
        let chain = TuiChain {
            end_block: Some(2_000_000),
            ..syncing("1")
        };
        insta::assert_snapshot!(render(&state(&[chain], Messages::Loading), 40));
    }

    #[test]
    fn calculates_the_eta_before_every_chain_reports_a_height() {
        let waiting = TuiChain {
            first_event_block_number: None,
            progress_block_number: -1,
            latest_fetched_block_number: 999_999,
            known_height: 0,
            source_block_number: 0,
            num_events_processed: 0.,
            ..syncing("137")
        };
        insta::assert_snapshot!(render(
            &state(&[syncing("1"), waiting], Messages::Loaded(vec![])),
            100
        ));
    }

    #[test]
    fn falls_back_to_256_colours_without_truecolor() {
        let palette = Palette { truecolor: false };
        assert_eq!(
            (
                palette.secondary(),
                palette.rgb((0x80, 0x80, 0x80)),
                palette.rgb((0, 0, 0))
            ),
            (Color::Indexed(221), Color::Indexed(244), Color::Indexed(16))
        );
    }

    #[test]
    fn wraps_long_lines_at_the_terminal_width() {
        let wrapped = wrap(
            vec![
                Line::from(vec![Span::raw("abcd").bold(), Span::raw("efg")]),
                Line::default(),
                Line::raw("⚡⚡⚡"),
            ],
            3,
        );
        assert_eq!(
            wrapped,
            vec![
                Line::from(vec![Span::raw("abc").bold()]),
                Line::from(vec![Span::raw("d").bold(), Span::raw("ef")]),
                Line::from(vec![Span::raw("g")]),
                Line::from(Vec::<Span>::new()),
                Line::from(vec![Span::raw("⚡")]),
                Line::from(vec![Span::raw("⚡")]),
                Line::from(vec![Span::raw("⚡")]),
            ]
        );
    }
}
