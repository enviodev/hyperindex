use super::{
    format, logo,
    state::{Chain, Eta, Messages, Progress, State, TuiInfo},
};
use ratatui::{
    style::{Color, Style},
    text::{Line, Span},
};
use unicode_width::UnicodeWidthChar;

const SPINNER: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
pub const SPINNER_INTERVAL_MS: u64 = 80;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ColorLevel {
    None,
    Basic,
    Ansi256,
    TrueColor,
}

impl ColorLevel {
    /// What the terminal supports, read from the environment the way chalk
    /// read it: `FORCE_COLOR` sets a minimum, and `NO_COLOR` or
    /// `FORCE_COLOR=0` turn colour off.
    pub fn detect(var: impl Fn(&str) -> Option<String>) -> Self {
        let forced = var("FORCE_COLOR").map(|value| match value.as_str() {
            "0" | "false" => ColorLevel::None,
            "2" => ColorLevel::Ansi256,
            "3" => ColorLevel::TrueColor,
            _ => ColorLevel::Basic,
        });
        if forced == Some(ColorLevel::None) || var("NO_COLOR").is_some_and(|v| !v.is_empty()) {
            return ColorLevel::None;
        }
        let detected = if var("COLORTERM").is_some_and(|value| {
            value.eq_ignore_ascii_case("truecolor") || value.eq_ignore_ascii_case("24bit")
        }) {
            ColorLevel::TrueColor
        } else if var("TERM").is_some_and(|term| term.contains("256")) {
            ColorLevel::Ansi256
        } else {
            ColorLevel::Basic
        };
        forced.map_or(detected, |forced| {
            if forced as u8 > detected as u8 {
                forced
            } else {
                detected
            }
        })
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Palette {
    pub level: ColorLevel,
}

impl Palette {
    pub fn rgb(self, (r, g, b): (u8, u8, u8)) -> Color {
        match self.level {
            ColorLevel::TrueColor => Color::Rgb(r, g, b),
            ColorLevel::Ansi256 => Color::Indexed(ansi256(r, g, b)),
            ColorLevel::Basic => basic(ansi256(r, g, b)),
            ColorLevel::None => Color::Reset,
        }
    }
    fn named(self, color: Color) -> Color {
        match self.level {
            ColorLevel::None => Color::Reset,
            _ => color,
        }
    }
    // The terminal's own foreground, so the text follows its theme.
    fn text(self) -> Style {
        Style::new()
    }
    fn dim(self) -> Style {
        Style::new().fg(self.rgb((0x8A, 0x87, 0x81)))
    }
    fn faint(self) -> Style {
        Style::new().fg(self.named(Color::DarkGray))
    }
    fn gold(self) -> Style {
        Style::new().fg(self.rgb((0xD9, 0xB3, 0x6C)))
    }
    fn green(self) -> Style {
        Style::new().fg(self.rgb((0x8F, 0xBF, 0x7F)))
    }
    fn red(self) -> Style {
        Style::new().fg(self.rgb((0xE0, 0x80, 0x6B)))
    }
    fn link(self) -> Style {
        self.text().underlined()
    }
    /// The colours envio's server names its messages by.
    fn message(self, name: &str) -> Color {
        match name {
            "primary" => self.rgb((0x98, 0x60, 0xE5)),
            "secondary" => self.rgb((0xFF, 0xBB, 0x2F)),
            "info" => self.rgb((0x6C, 0xBF, 0xEE)),
            "danger" => self.rgb((0xFF, 0x82, 0x69)),
            "success" => self.rgb((0x3B, 0x8C, 0x3D)),
            "gray" => self.named(Color::DarkGray),
            _ => self.named(Color::Gray),
        }
    }
}

/// The xterm 256-colour cube.
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

/// The closest of the 16 standard colours to a 256-colour code.
fn basic(code: u8) -> Color {
    let (r, g, b) = if code >= 232 {
        let level = ((code - 232) as f64 * 10. + 8.) / 255.;
        (level, level, level)
    } else {
        let cube = code.saturating_sub(16);
        (
            (cube / 36) as f64 / 5.,
            (cube % 36 / 6) as f64 / 5.,
            (cube % 6) as f64 / 5.,
        )
    };
    let bright = r.max(g).max(b) == 1.;
    let index = ((b.round() as u8) << 2) | ((g.round() as u8) << 1) | r.round() as u8;
    const NORMAL: [Color; 8] = [
        Color::Black,
        Color::Red,
        Color::Green,
        Color::Yellow,
        Color::Blue,
        Color::Magenta,
        Color::Cyan,
        Color::Gray,
    ];
    const BRIGHT: [Color; 8] = [
        Color::DarkGray,
        Color::LightRed,
        Color::LightGreen,
        Color::LightYellow,
        Color::LightBlue,
        Color::LightMagenta,
        Color::LightCyan,
        Color::White,
    ];
    if bright {
        BRIGHT[index as usize]
    } else {
        NORMAL[index as usize]
    }
}

type Spans = Vec<Span<'static>>;

fn span(text: impl Into<String>, style: Style) -> Span<'static> {
    Span::styled(text.into(), style)
}

fn width(spans: &[Span]) -> usize {
    spans.iter().map(Span::width).sum()
}

#[derive(Clone, Copy)]
enum Align {
    Left,
    Right,
    Center,
}

fn pad(spans: Spans, to: usize, align: Align) -> Spans {
    let gap = to.saturating_sub(width(&spans));
    let (before, after) = match align {
        Align::Left => (0, gap),
        Align::Right => (gap, 0),
        Align::Center => (gap / 2, gap - gap / 2),
    };
    let mut out = Vec::with_capacity(spans.len() + 2);
    if before > 0 {
        out.push(Span::raw(" ".repeat(before)));
    }
    out.extend(spans);
    if after > 0 {
        out.push(Span::raw(" ".repeat(after)));
    }
    out
}

/// Joins cells one space apart.
fn row(cells: Vec<Spans>) -> Line<'static> {
    let mut spans = Vec::new();
    for (i, cell) in cells.into_iter().enumerate() {
        if i > 0 {
            spans.push(Span::raw(" "));
        }
        spans.extend(cell);
    }
    Line::from(spans)
}

fn display_name(chain: &Chain) -> String {
    chain
        .name
        .clone()
        .unwrap_or_else(|| format!("Chain {}", chain.chain_id))
}

fn chain_name(chain: &Chain, palette: Palette) -> Spans {
    let mut spans = vec![
        span(
            chain.name.clone().unwrap_or_else(|| "Chain".to_string()),
            palette.text().bold(),
        ),
        Span::raw(" "),
        span(chain.chain_id.clone(), palette.faint()),
    ];
    if !chain.powered_by_hyper_sync {
        spans.push(span(" rpc", palette.dim()));
    }
    spans
}

/// How far `block` is through the blocks the chain counts up to.
fn fraction(chain: &Chain, block: i64) -> f64 {
    let range = chain.to_block - chain.start_block;
    if range > 0 {
        ((block - chain.start_block) as f64 / range as f64).clamp(0., 1.)
    } else {
        0.
    }
}

fn percentage(chain: &Chain, palette: Palette) -> Spans {
    vec![match chain.progress {
        Progress::Synced { .. } => span("✓", palette.green()),
        Progress::SearchingForEvents => span("…", palette.dim()),
        Progress::Syncing { .. } => span(
            format!(
                "{}%",
                (fraction(chain, chain.progress_block) * 100.).floor()
            ),
            if chain.is_rate_limited() {
                palette.red()
            } else {
                palette.text()
            },
        ),
    }]
}

/// The figures are what keep a percentage honest, so the current block is
/// shown in full and only the height it counts up to is shortened.
#[derive(Clone, Copy, PartialEq)]
enum Blocks {
    WithUnit,
    Plain,
    Tight,
}

fn blocks(chain: &Chain, form: Blocks, unit: &str, palette: Palette) -> Spans {
    let of = |block: i64| {
        vec![
            span(format::number(block as f64), palette.text()),
            span("/", palette.faint()),
            span(format::compact(chain.to_block as f64), palette.dim()),
        ]
    };
    match chain.progress {
        Progress::Synced {
            latest_processed_block,
            ..
        } => {
            let block = span(
                format::number(latest_processed_block.max(chain.start_block) as f64),
                palette.text(),
            );
            if form == Blocks::Tight {
                vec![block]
            } else {
                let at = if chain.end_block.is_some() {
                    "at end "
                } else {
                    "at head "
                };
                vec![span(at, palette.dim()), block]
            }
        }
        Progress::SearchingForEvents if form != Blocks::Tight => [
            vec![span("searching ", palette.dim())],
            of(chain.buffer_block),
        ]
        .concat(),
        Progress::SearchingForEvents => of(chain.buffer_block),
        Progress::Syncing { .. } if form == Blocks::WithUnit => [
            of(chain.progress_block),
            vec![span(format!(" {unit}"), palette.faint())],
        ]
        .concat(),
        Progress::Syncing { .. } => of(chain.progress_block),
    }
}

/// Always with the unit: a bare count beside the blocks reads as anything.
fn events(chain: &Chain, palette: Palette) -> Spans {
    if chain.events_processed > 0. {
        vec![
            span(format::compact(chain.events_processed), palette.text()),
            span(" events", palette.faint()),
        ]
    } else {
        vec![span("no events", palette.faint())]
    }
}

fn bar(chain: &Chain, width: usize, palette: Palette) -> Spans {
    let cells = |block: i64| ((fraction(chain, block) * width as f64).round() as usize).min(width);
    let (lit, buffered) = match chain.progress {
        Progress::Synced { .. } => (width, width),
        Progress::SearchingForEvents => (0, cells(chain.buffer_block)),
        Progress::Syncing { .. } => {
            let lit = cells(chain.progress_block);
            (lit, cells(chain.buffer_block).max(lit))
        }
    };
    let mut spans: Spans = (0..lit)
        .map(|i| {
            let position = i as f64 / (width.max(2) - 1) as f64;
            span("━", Style::new().fg(palette.rgb(logo::gradient(position))))
        })
        .collect();
    // Without colour, fetched blocks would look processed.
    let buffer = if palette.level == ColorLevel::None {
        "─"
    } else {
        "━"
    };
    spans.push(span(buffer.repeat(buffered - lit), palette.faint()));
    spans.push(span("─".repeat(width - buffered), palette.faint()));
    spans
}

const MIN_BAR: usize = 12;
const MAX_BAR: usize = 40;
const MIN_FOLDED_BAR: usize = 8;

/// Columns as wide as their widest value, one space apart, with the bar
/// taking what's left. When it would get too short, the least important
/// detail goes first: the blocks' unit, then the events, then each chain
/// folds onto two lines.
fn chain_rows(state: &State, inner: usize, palette: Palette) -> Vec<Line<'static>> {
    let chains = &state.chains;
    if chains.is_empty() {
        return vec![];
    }
    let unit = if state.info.ecosystem == "svm" {
        "slots"
    } else {
        "blocks"
    };
    let widest = |cell: &dyn Fn(&Chain) -> Spans| {
        chains
            .iter()
            .map(|chain| width(&cell(chain)))
            .max()
            .unwrap_or(0)
    };
    let name = |chain: &Chain| chain_name(chain, palette);
    let pct = |chain: &Chain| percentage(chain, palette);
    let events = |chain: &Chain| events(chain, palette);
    let name_width = widest(&name);
    let pct_width = widest(&pct).max(3);
    let pct_cell = |chain: &Chain| {
        let align = match chain.progress {
            Progress::Syncing { .. } => Align::Right,
            _ => Align::Center,
        };
        pad(pct(chain), pct_width, align)
    };
    let fixed = |form: Blocks, with_events: bool| {
        let blocks_width = widest(&|chain| blocks(chain, form, unit, palette));
        let events_width = if with_events { 1 + widest(&events) } else { 0 };
        (
            blocks_width,
            events_width,
            1 + pct_width + 1 + blocks_width + events_width,
        )
    };
    let cells = |chain: &Chain, bar_width, form, blocks_width, with_events: bool, events_width| {
        let mut cells = vec![
            pct_cell(chain),
            pad(
                blocks(chain, form, unit, palette),
                blocks_width,
                Align::Left,
            ),
        ];
        if bar_width > 0 {
            cells.insert(0, bar(chain, bar_width, palette));
        }
        if with_events {
            cells.push(pad(events(chain), events_width - 1, Align::Right));
        }
        cells
    };

    for (form, with_events) in [
        (Blocks::WithUnit, true),
        (Blocks::Plain, true),
        (Blocks::Plain, false),
    ] {
        let (blocks_width, events_width, fixed) = fixed(form, with_events);
        let room = inner.saturating_sub(name_width + 1 + fixed);
        if room < MIN_BAR {
            continue;
        }
        let bar_width = room.min(MAX_BAR);
        return chains
            .iter()
            .map(|chain| {
                let mut row_cells = vec![pad(name(chain), name_width, Align::Left)];
                row_cells.extend(cells(
                    chain,
                    bar_width,
                    form,
                    blocks_width,
                    with_events,
                    events_width,
                ));
                row(row_cells)
            })
            .collect();
    }

    // Events only stay when they fit beside the bar: on a line of their own
    // they'd read as belonging to the next chain.
    let folded = [
        (Blocks::Plain, true),
        (Blocks::Plain, false),
        (Blocks::Tight, false),
    ];
    let (form, with_events) = folded
        .into_iter()
        .find(|(form, with_events)| {
            inner.saturating_sub(fixed(*form, *with_events).2) >= MIN_FOLDED_BAR
        })
        .unwrap_or((Blocks::Tight, false));
    let (blocks_width, events_width, fixed) = fixed(form, with_events);
    // Too narrow for a bar that shows anything, the percentage says it alone.
    let bar_width = match inner.saturating_sub(fixed) {
        room if room >= MIN_FOLDED_BAR / 2 => room,
        _ => 0,
    };
    chains
        .iter()
        .flat_map(|chain| {
            [
                Line::from(name(chain)),
                row(cells(
                    chain,
                    bar_width,
                    form,
                    blocks_width,
                    with_events,
                    events_width,
                )),
            ]
        })
        .collect()
}

fn title(info: &TuiInfo, path: &str, palette: Palette) -> Line<'static> {
    let mut spans = vec![span("envio", palette.text().bold())];
    if !info.version.is_empty() {
        spans.push(span(format!("@{}", info.version), palette.dim()));
    }
    if !path.is_empty() {
        spans.push(Span::raw(" "));
        spans.push(span(path.to_string(), palette.faint()));
    }
    Line::from(spans)
}

/// Shortened from the left: the end of the path is what names the project.
fn fit_title(info: &TuiInfo, inner: usize, palette: Palette) -> Line<'static> {
    let path = &info.project_dir;
    let parts: Vec<&str> = path.split('/').collect();
    let shortened = (1..parts.len()).map(|i| format!("…/{}", parts[i..].join("/")));
    std::iter::once(path.clone())
        .chain(shortened)
        .map(|path| title(info, &path, palette))
        .find(|line| line.width() <= inner)
        .unwrap_or_else(|| title(info, "", palette))
}

/// The run as one sentence: where it is, when it'll be done, how much it did.
fn summary(
    state: &State,
    now: f64,
    tick: usize,
    inner: usize,
    palette: Palette,
) -> Vec<Line<'static>> {
    let separator = || span(" · ", palette.faint());
    let spinner = || span(SPINNER[tick % SPINNER.len()], palette.gold());
    let status = match state.eta(now) {
        Eta::Synced(took) => vec![
            span("✓ synced", palette.green()),
            span(format!(" in {took}"), palette.dim()),
        ],
        Eta::Syncing(eta) => vec![
            spinner(),
            span(" syncing", palette.text()),
            separator(),
            span("ETA ", palette.dim()),
            span(eta, palette.text().bold()),
        ],
        Eta::Calculating => vec![
            spinner(),
            span(" syncing", palette.text()),
            separator(),
            span("calculating ETA", palette.dim()),
        ],
    };
    let mut totals = vec![
        span(format::number(state.total_events()), palette.text().bold()),
        span(" events", palette.dim()),
    ];
    if let (false, Some(per_second)) = (state.is_fully_synced(), state.events_per_second()) {
        totals.push(separator());
        totals.push(span(
            format!("{}/s", format::number(per_second)),
            palette.text(),
        ));
    }
    if width(&status) + 3 + width(&totals) <= inner {
        vec![Line::from([status, vec![separator()], totals].concat())]
    } else {
        [status, totals]
            .into_iter()
            .flat_map(|part| wrap_words(part, inner, 0))
            .collect()
    }
}

fn links(info: &TuiInfo, inner: usize, palette: Palette) -> Vec<Line<'static>> {
    let link = |label: &str, url: &str| {
        vec![
            span(format!("{label} "), palette.dim()),
            span(url.to_string(), palette.link()),
        ]
    };
    let graphql = link("GraphQL", &info.graphql_url);
    let secret = info
        .graphql_password
        .as_ref()
        .map(|password| format!("admin secret: {password}"));
    let graphql_with_secret = match &secret {
        Some(secret) => [
            graphql.clone(),
            vec![span(format!(" ({secret})"), palette.faint())],
        ]
        .concat(),
        None => graphql.clone(),
    };
    let others: Vec<Spans> = [
        info.dev_console_url
            .as_ref()
            .map(|url| link("Console", url)),
        info.clickhouse_url
            .as_ref()
            .map(|url| link("ClickHouse", url)),
    ]
    .into_iter()
    .flatten()
    .collect();

    let one_line =
        width(&graphql_with_secret) + others.iter().map(|other| 3 + width(other)).sum::<usize>();
    if one_line <= inner {
        let mut spans = graphql_with_secret;
        for other in others {
            spans.push(Span::raw("   "));
            spans.extend(other);
        }
        return vec![Line::from(spans)];
    }
    let mut lines = match secret {
        Some(secret) if width(&graphql_with_secret) > inner => {
            // Under the URL, unless that's what would make it wrap.
            let indent = "GraphQL ".len();
            let indent = if indent + secret.len() <= inner {
                indent
            } else {
                0
            };
            vec![
                Line::from(graphql),
                Line::from(vec![
                    Span::raw(" ".repeat(indent)),
                    span(secret, palette.faint()),
                ]),
            ]
        }
        _ => vec![Line::from(graphql_with_secret)],
    };
    lines.extend(others.into_iter().map(Line::from));
    lines
}

fn notices(state: &State, inner: usize, palette: Palette) -> Vec<Line<'static>> {
    let mut notices: Vec<Vec<Spans>> = Vec::new();
    if let Some((time_ms, reset_in_ms)) = state.rate_limit() {
        let limited: Vec<String> = state
            .chains
            .iter()
            .filter(|chain| chain.is_rate_limited())
            .map(display_name)
            .collect();
        let verb = if limited.len() == 1 { "is" } else { "are" };
        let mut headline = vec![
            span("▲ ", palette.red()),
            span(
                format!("{} {verb} rate limited by HyperSync", limited.join(", ")),
                palette.text(),
            ),
            span(
                format!(" · {}s slower so far", format::number(time_ms / 1000.)),
                palette.dim(),
            ),
        ];
        if reset_in_ms > 0. {
            headline.push(span(
                format!(
                    " · resets in {}s",
                    format::number((reset_in_ms / 1000.).ceil().max(1.))
                ),
                palette.dim(),
            ));
        }
        notices.push(vec![
            headline,
            vec![
                span("  Raise the limit with an API token: ", palette.dim()),
                span("https://envio.dev/app/api-tokens", palette.link()),
            ],
        ]);
    }
    match &state.messages {
        Messages::Loading => {}
        Messages::Loaded(messages) => {
            for message in messages {
                notices.push(vec![vec![
                    span("● ", Style::new().fg(palette.message(&message.color))),
                    span(message.content.clone(), palette.text()),
                ]]);
            }
        }
        Messages::Failed => notices.push(vec![vec![
            span("▲ ", palette.red()),
            span("Failed to load messages from envio server", palette.text()),
        ]]),
    }
    notices
        .into_iter()
        .flatten()
        .flat_map(|spans| wrap_words(spans, inner, 2))
        .collect()
}

/// Breaks between words, continuing each line `indent` columns in, under the
/// text that follows a notice's marker.
fn wrap_words(spans: Spans, width: usize, indent: usize) -> Vec<Line<'static>> {
    let lead = spans.first().map_or(0, |span| {
        span.content.len() - span.content.trim_start_matches(' ').len()
    });
    let mut words: Vec<(String, Style, bool)> = Vec::new();
    let mut spaced = false;
    for span in spans {
        for (i, word) in span.content.split(' ').enumerate() {
            spaced |= i > 0;
            if !word.is_empty() {
                words.push((word.to_string(), span.style, spaced));
                spaced = false;
            }
        }
    }
    let mut lines = Vec::new();
    let mut line: Spans = vec![Span::raw(" ".repeat(lead))];
    let mut used = lead;
    let mut empty = true;
    for (word, style, spaced) in words {
        let word_width = Span::raw(word.as_str()).width();
        let gap = usize::from(spaced && !empty);
        if !empty && used + gap + word_width > width {
            lines.push(Line::from(std::mem::take(&mut line)));
            line = vec![Span::raw(" ".repeat(indent))];
            used = indent;
        } else if gap > 0 {
            line.push(Span::raw(" "));
            used += 1;
        }
        line.push(Span::styled(word, style));
        used += word_width;
        empty = false;
    }
    lines.push(Line::from(line));
    lines
}

/// The frame at most `height` rows tall: the logo goes first when it doesn't fit.
pub fn frame(
    state: &State,
    now: f64,
    tick: usize,
    width: u16,
    height: u16,
    palette: Palette,
) -> Vec<Line<'static>> {
    let (width, height) = (width as usize, height as usize);
    let margin = if width >= 30 { 2 } else { 0 };
    let inner = width.saturating_sub(margin * 2).max(1);

    let rows = chain_rows(state, inner, palette);
    let title = fit_title(&state.info, inner, palette);
    // As wide as its content, so on a wide terminal the logo centres over the
    // rows rather than the screen.
    let content_width = rows
        .iter()
        .map(Line::width)
        .chain([title.width()])
        .max()
        .unwrap_or(0)
        .min(inner);
    let logo: Vec<Line<'static>> = if inner >= logo::width() + 2 {
        let indent = content_width.saturating_sub(logo::width()) / 2;
        logo::lines(tick, |color| palette.rgb(color))
            .into_iter()
            .map(|line| {
                let mut spans = vec![Span::raw(" ".repeat(indent))];
                spans.extend(line.spans);
                Line::from(spans)
            })
            .chain([Line::default()])
            .collect()
    } else {
        vec![]
    };

    let mut body = Vec::new();
    if !rows.is_empty() {
        body.extend(rows);
        body.push(Line::default());
    }
    body.extend(summary(state, now, tick, inner, palette));
    body.push(Line::default());
    body.extend(links(&state.info, inner, palette));
    let notices = notices(state, inner, palette);
    if !notices.is_empty() {
        body.push(Line::default());
        body.extend(notices);
    }

    let lay_out = |sections: Vec<Line<'static>>| {
        let indented = sections
            .into_iter()
            .map(|line| {
                if margin == 0 || line.spans.is_empty() {
                    return line;
                }
                let mut spans = vec![Span::raw(" ".repeat(margin))];
                spans.extend(line.spans);
                Line::from(spans)
            })
            .collect();
        wrap(indented, width)
    };
    let head = vec![title, Line::default()];
    let full = lay_out([head.clone(), logo, body.clone()].concat());
    let mut lines = if full.len() <= height {
        full
    } else {
        lay_out([head, body].concat())
    };
    lines.truncate(height);
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
    use crate::tui::session::Size;
    use crate::tui::state::{TuiChain, TuiInfo, TuiMessage};
    use crate::tui::testing::{self, Emulator};
    use ratatui::style::Stylize;

    const NOW: f64 = 1_700_000_100_000.;
    const START: f64 = 1_700_000_000_000.;

    fn info() -> TuiInfo {
        TuiInfo {
            ecosystem: "evm".to_string(),
            version: "2.32.0".to_string(),
            project_dir: "~/code/projects/envio/uniswap-indexer".to_string(),
            start_time: START,
            graphql_url: "http://localhost:8080".to_string(),
            graphql_password: Some("testing".to_string()),
            dev_console_url: Some("https://envio.dev/console".to_string()),
            clickhouse_url: None,
        }
    }

    fn ethereum() -> TuiChain {
        TuiChain {
            chain_id: "1".to_string(),
            powered_by_hyper_sync: true,
            start_block: 10_000_000,
            end_block: None,
            first_event_block_number: Some(10_000_000),
            progress_block_number: 16_820_000,
            processed_to_endblock: false,
            latest_fetched_block_number: 17_980_000,
            known_height: 21_000_000,
            source_block_number: 21_000_000,
            timestamp_caught_up_to_head_or_endblock: None,
            num_events_processed: 1_204_881.,
            rate_limit_time_ms: 0.,
            rate_limit_reset_in_ms: None,
        }
    }

    fn base() -> TuiChain {
        TuiChain {
            chain_id: "8453".to_string(),
            start_block: 2_000_000,
            first_event_block_number: Some(2_000_000),
            progress_block_number: 24_118_903,
            latest_fetched_block_number: 24_118_903,
            known_height: 24_118_903,
            source_block_number: 24_118_903,
            timestamp_caught_up_to_head_or_endblock: Some(START + 60_000.),
            num_events_processed: 903_412.,
            ..ethereum()
        }
    }

    fn arbitrum() -> TuiChain {
        TuiChain {
            chain_id: "42161".to_string(),
            start_block: 50_000_000,
            first_event_block_number: Some(50_000_000),
            progress_block_number: 120_344_364,
            latest_fetched_block_number: 150_000_000,
            known_height: 301_229_870,
            source_block_number: 301_229_870,
            num_events_processed: 372_741.,
            ..ethereum()
        }
    }

    fn gnosis_over_rpc() -> TuiChain {
        TuiChain {
            chain_id: "100".to_string(),
            powered_by_hyper_sync: false,
            start_block: 25_000_000,
            first_event_block_number: None,
            progress_block_number: -1,
            latest_fetched_block_number: 30_120_455,
            known_height: 38_772_010,
            source_block_number: 38_772_010,
            num_events_processed: 0.,
            ..ethereum()
        }
    }

    fn synced(chain: TuiChain, end_block: Option<i64>) -> TuiChain {
        let head = end_block.unwrap_or(chain.known_height);
        TuiChain {
            end_block,
            first_event_block_number: chain.first_event_block_number.or(Some(chain.start_block)),
            progress_block_number: head,
            processed_to_endblock: end_block.is_some(),
            latest_fetched_block_number: head,
            known_height: head,
            timestamp_caught_up_to_head_or_endblock: Some(START + 242_000.),
            ..chain
        }
    }

    fn news() -> Messages {
        Messages::Loaded(vec![TuiMessage {
            color: "secondary".to_string(),
            content: "Base HyperSync is 2x faster! pnpm up envio".to_string(),
        }])
    }

    /// Ten seconds of indexing at 5,000 events a second, ending at `NOW`.
    fn state(chains: &[TuiChain], messages: Messages) -> State {
        let mut state = State::new(info());
        let earlier: Vec<TuiChain> = chains
            .iter()
            .map(|chain| TuiChain {
                num_events_processed: (chain.num_events_processed - 50_000.).max(0.),
                ..chain.clone()
            })
            .collect();
        state.update(&earlier, NOW - 10_000.);
        state.update(chains, NOW);
        state.messages = messages;
        state
    }

    fn syncing() -> State {
        state(&[ethereum(), synced(base(), None), arbitrum()], news())
    }

    fn trouble() -> State {
        let limited = TuiChain {
            rate_limit_time_ms: 9_400.,
            rate_limit_reset_in_ms: Some(2_100.),
            ..ethereum()
        };
        state(
            &[limited, synced(base(), None), gnosis_over_rpc()],
            Messages::Loaded(vec![]),
        )
    }

    /// Draws the whole display into an emulator and snapshots what it shows.
    fn assert_screen(name: &str, state: &State, width: u16, level: ColorLevel) {
        let size = Size { width, height: 40 };
        let emulator = Emulator::new(size);
        emulator
            .session_with(level)
            .render(None, state, NOW, 3, size)
            .unwrap();
        testing::assert_screen(name, &emulator);
    }

    #[test]
    fn lays_chains_out_in_columns_on_a_wide_terminal() {
        assert_screen("syncing_wide", &syncing(), 100, ColorLevel::TrueColor);
    }

    #[test]
    fn drops_the_blocks_unit_then_the_events_as_the_terminal_narrows() {
        assert_screen("syncing_80", &syncing(), 80, ColorLevel::TrueColor);
        assert_screen("syncing_72", &syncing(), 72, ColorLevel::TrueColor);
    }

    #[test]
    fn folds_each_chain_onto_two_lines_on_a_narrow_terminal() {
        assert_screen("syncing_56", &syncing(), 56, ColorLevel::TrueColor);
        assert_screen("syncing_40", &syncing(), 40, ColorLevel::TrueColor);
    }

    #[test]
    fn drops_the_logo_and_margin_on_a_tiny_terminal() {
        assert_screen("syncing_24", &syncing(), 24, ColorLevel::TrueColor);
    }

    #[test]
    fn flags_a_rate_limited_chain_and_one_searching_over_rpc() {
        assert_screen("trouble_wide", &trouble(), 100, ColorLevel::TrueColor);
        assert_screen("trouble_48", &trouble(), 48, ColorLevel::TrueColor);
    }

    #[test]
    fn renders_a_synced_run_with_every_link() {
        let mut state = state(
            &[
                synced(ethereum(), Some(21_000_000)),
                synced(base(), None),
                synced(arbitrum(), None),
            ],
            Messages::Failed,
        );
        state.info.clickhouse_url = Some("http://localhost:8123/play".to_string());
        assert_screen("synced", &state, 100, ColorLevel::TrueColor);
    }

    #[test]
    fn calculates_the_eta_before_every_chain_reports_a_height() {
        let waiting = TuiChain {
            chain_id: "137".to_string(),
            first_event_block_number: None,
            progress_block_number: -1,
            latest_fetched_block_number: 9_999_999,
            known_height: 0,
            source_block_number: 0,
            num_events_processed: 0.,
            ..ethereum()
        };
        assert_screen(
            "calculating_eta",
            &state(&[ethereum(), waiting], Messages::Loading),
            100,
            ColorLevel::TrueColor,
        );
    }

    #[test]
    fn names_chains_it_does_not_know_by_id() {
        let mut state = state(&[ethereum()], Messages::Loading);
        state.info.ecosystem = "fuel".to_string();
        state.update(&[ethereum()], NOW);
        assert_screen("unknown_chain", &state, 80, ColorLevel::TrueColor);
    }

    #[test]
    fn renders_on_terminals_with_fewer_colours() {
        for (name, level) in [
            ("ansi256", ColorLevel::Ansi256),
            ("basic_colours", ColorLevel::Basic),
            ("no_colour", ColorLevel::None),
        ] {
            assert_screen(name, &syncing(), 100, level);
        }
    }

    #[test]
    fn flows_the_logo_over_ticks() {
        let size = Size {
            width: 100,
            height: 40,
        };
        let logo_at = |tick| {
            frame(
                &syncing(),
                NOW,
                tick,
                size.width,
                size.height,
                Palette {
                    level: ColorLevel::TrueColor,
                },
            )[2]
            .clone()
        };
        assert_ne!(logo_at(0), logo_at(10));
    }

    #[test]
    fn detects_the_colour_level_as_chalk_did() {
        let detect = |vars: &[(&str, &str)]| {
            ColorLevel::detect(|name| {
                vars.iter()
                    .find(|(key, _)| *key == name)
                    .map(|(_, value)| value.to_string())
            })
        };
        assert_eq!(
            [
                detect(&[("COLORTERM", "truecolor"), ("TERM", "xterm-256color")]),
                detect(&[("TERM", "xterm-256color")]),
                detect(&[("TERM", "linux")]),
                detect(&[("TERM", "linux"), ("FORCE_COLOR", "2")]),
                detect(&[("COLORTERM", "truecolor"), ("FORCE_COLOR", "1")]),
                detect(&[("COLORTERM", "truecolor"), ("NO_COLOR", "1")]),
                detect(&[("COLORTERM", "truecolor"), ("FORCE_COLOR", "0")]),
            ],
            [
                ColorLevel::TrueColor,
                ColorLevel::Ansi256,
                ColorLevel::Basic,
                ColorLevel::Ansi256,
                ColorLevel::TrueColor,
                ColorLevel::None,
                ColorLevel::None,
            ]
        );
    }

    // The 256 and 16 colour codes chalk's ansi-styles picks for the same hex.
    #[test]
    fn downsamples_colours_to_the_terminal_level() {
        let secondary = |level| Palette { level }.message("secondary");
        assert_eq!(
            [
                ColorLevel::TrueColor,
                ColorLevel::Ansi256,
                ColorLevel::Basic,
                ColorLevel::None
            ]
            .map(secondary),
            [
                Color::Rgb(255, 187, 47),
                Color::Indexed(221),
                Color::LightYellow,
                Color::Reset
            ]
        );
    }

    #[test]
    fn wraps_notices_between_words_under_their_text() {
        let wrapped: Vec<String> = wrap_words(
            vec![
                Span::raw("▲ "),
                Span::raw("Ethereum is rate limited"),
                Span::raw(" · 9s slower"),
            ],
            14,
            2,
        )
        .iter()
        .map(Line::to_string)
        .collect();
        assert_eq!(
            wrapped,
            ["▲ Ethereum is", "  rate limited", "  · 9s slower"]
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
