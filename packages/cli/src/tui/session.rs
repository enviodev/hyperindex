use super::render::{self, Palette};
use super::state::State;
use ratatui::{
    style::{Color, Modifier, Style},
    text::Line,
};
use std::io::{self, Write};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Size {
    pub width: u16,
    pub height: u16,
}

impl Size {
    /// A PTY can report zero for a size its client hasn't sent yet, as
    /// `docker run -t` does until the first resize: assume the classic width,
    /// and no limit on the height rather than a frame of none.
    pub fn reported(columns: u16, rows: u16) -> Self {
        Size {
            width: if columns == 0 { 80 } else { columns },
            height: if rows == 0 { u16::MAX } else { rows },
        }
    }

    /// `None` while the height is unknown.
    fn rows_above_cursor(self) -> Option<usize> {
        (self.height != u16::MAX).then(|| self.height.saturating_sub(1) as usize)
    }
}

/// The display, pinned to the bottom of the terminal with the output right
/// above it. It moves the cursor relative to where it left it, so it never
/// has to ask the terminal where that is, and printed lines scroll off the
/// top the way any output does, into the terminal's own scrollback.
///
/// The cursor rests on the bottom row, below the frame. A terminal narrowing
/// rewraps the frame onto more rows, which it makes room for by pushing
/// what's above off the top; anchored at the bottom, that's the output,
/// while a frame higher up would lose its own top rows to the scrollback,
/// where no redraw can erase them.
pub struct Session<W: Write> {
    out: W,
    palette: Palette,
    /// The frame on screen, kept to erase it and to skip redrawing it as is.
    drawn: Vec<Line<'static>>,
    drawn_size: Option<Size>,
    /// Blank rows at the top of the screen, from taking it on the first draw
    /// or from the frame shrinking, which output takes before it scrolls, so
    /// none of them reach the scrollback.
    blank: usize,
    /// Where the terminal had the cursor before the first draw, as row and
    /// column from 0, when it said.
    started_at: Option<(u16, u16)>,
}

impl<W: Write> Session<W> {
    pub fn new(out: W, palette: Palette) -> Self {
        Session {
            out,
            palette,
            drawn: Vec::new(),
            drawn_size: None,
            blank: 0,
            started_at: None,
        }
    }

    /// Lets the first draw keep what the terminal shows right above the frame
    /// instead of scrolling it off the screen.
    pub fn started_at(&mut self, cursor: (u16, u16)) {
        self.started_at = Some(cursor);
    }

    /// The rows the frame on screen takes at `size`: a narrower terminal may
    /// have rewrapped its lines onto more of them.
    fn drawn_rows(&self, size: Size) -> usize {
        match self.drawn_size {
            Some(drawn) if size.width < drawn.width => self
                .drawn
                .iter()
                .map(|line| line.width().div_ceil(size.width.max(1) as usize).max(1))
                .sum(),
            _ => self.drawn.len(),
        }
    }

    fn frame(&self, state: &State, now: f64, tick: usize, size: Size) -> Vec<Line<'static>> {
        // Rows that scroll off the top can't be erased, so they'd pile up in
        // the scrollback on every redraw.
        let height = size.height.saturating_sub(1).max(1);
        render::frame(state, now, tick, size.width, height, self.palette)
    }

    /// Rewrites the rows that differ from the frame on screen in place, with
    /// the cursor left below the frame as a full redraw leaves it.
    fn patch(&self, buf: &mut Vec<u8>, lines: &[Line<'static>]) {
        let below = lines.len();
        let mut row = below;
        for (i, (line, drawn)) in lines.iter().zip(&self.drawn).enumerate() {
            if line == drawn {
                continue;
            }
            if i < row {
                buf.extend(format!("\x1b[{}A", row - i).as_bytes());
            } else if i > row {
                buf.extend(format!("\x1b[{}B", i - row).as_bytes());
            }
            // Cleared before writing: clearing after a row that fills the
            // width would take its last character with it.
            buf.extend(b"\r\x1b[K");
            encode(buf, line);
            row = i;
        }
        if row < below {
            buf.extend(format!("\x1b[{}B", below - row).as_bytes());
        }
        buf.push(b'\r');
    }

    /// Prints `printed` above the display and redraws it, as one synchronized
    /// update so terminals that support it never show the display erased.
    /// With `last`, the blank rows at the top go, so the shell carries on
    /// right below the frame.
    fn draw(
        &mut self,
        printed: Option<&str>,
        lines: Vec<Line<'static>>,
        size: Size,
        last: bool,
    ) -> io::Result<()> {
        let mut buf = BEGIN_SYNCHRONIZED_UPDATE.to_vec();
        let pinned = size.rows_above_cursor();
        match (self.drawn_size, pinned, self.started_at) {
            // Moves what the terminal shows down to the bottom of the screen,
            // past a line it left unfinished, onto the blank rows below it.
            (None, Some(rows), Some((row, column))) => {
                let mut row = (row as usize).min(rows);
                if column > 0 {
                    buf.extend(b"\r\n");
                    row = (row + 1).min(rows);
                }
                self.blank = rows - row;
                if self.blank > 0 {
                    buf.extend(
                        format!("\x1b[{0}A\x1b[{1}L\x1b[{0}B", size.height, self.blank).as_bytes(),
                    );
                }
            }
            // Not knowing where the cursor is, takes the screen, scrolling
            // what was on it into the scrollback.
            (None, Some(rows), None) => {
                buf.extend(b"\r\n".repeat(rows));
                self.blank = rows;
            }
            // The terminal may have moved what's at the top of the screen.
            (Some(drawn), _, _) if drawn != size => self.blank = 0,
            _ => {}
        }
        let drawn_rows = self.drawn_rows(size);
        buf.push(b'\r');
        if drawn_rows > 0 {
            buf.extend(format!("\x1b[{drawn_rows}A").as_bytes());
        }
        buf.extend(b"\x1b[J");

        // Everything above moves down onto rows the frame no longer needs,
        // or up into blank ones, so the output stays right above the frame.
        let rows_needed = printed.map_or(0, |text| rows(text, size.width)) + lines.len();
        if let Some(height) = pinned {
            let (top, bottom) = (format!("\x1b[{height}A"), format!("\x1b[{height}B"));
            let start = if rows_needed < drawn_rows {
                let spare = drawn_rows - rows_needed;
                buf.extend(format!("{top}\x1b[{spare}L").as_bytes());
                self.blank += spare;
                rows_needed
            } else {
                let taken = (rows_needed - drawn_rows).min(self.blank);
                if taken > 0 {
                    buf.extend(format!("{top}\x1b[{taken}M").as_bytes());
                    self.blank -= taken;
                }
                drawn_rows + taken
            };
            // From the bottom row, which is also where a terminal grown
            // taller since the last draw pins the frame back to.
            buf.extend(format!("{bottom}\r").as_bytes());
            if start > 0 {
                buf.extend(format!("\x1b[{start}A").as_bytes());
            }
        }

        if let Some(text) = printed {
            buf.extend(text.replace('\n', "\r\n").as_bytes());
            buf.extend(b"\x1b[0m\r\n");
        }
        for line in &lines {
            encode(&mut buf, line);
            buf.extend(b"\r\n");
        }
        if let (true, Some(height), blank @ 1..) = (last, pinned, self.blank) {
            buf.extend(
                format!("\x1b[{height}A\x1b[{blank}M\x1b[{height}B\r\x1b[{blank}A").as_bytes(),
            );
            self.blank = 0;
        }
        buf.extend(END_SYNCHRONIZED_UPDATE);
        self.out.write_all(&buf)?;
        self.out.flush()?;
        self.drawn = lines;
        self.drawn_size = Some(size);
        Ok(())
    }

    pub fn render(
        &mut self,
        printed: Option<&str>,
        state: &State,
        now: f64,
        tick: usize,
        size: Size,
    ) -> io::Result<()> {
        let lines = self.frame(state, now, tick, size);
        let same_shape = self.drawn_size == Some(size) && lines.len() == self.drawn.len();
        match printed {
            None if same_shape && lines == self.drawn => Ok(()),
            None if same_shape => {
                let mut buf = BEGIN_SYNCHRONIZED_UPDATE.to_vec();
                self.patch(&mut buf, &lines);
                buf.extend(END_SYNCHRONIZED_UPDATE);
                self.out.write_all(&buf)?;
                self.out.flush()?;
                self.drawn = lines;
                Ok(())
            }
            _ => self.draw(printed, lines, size, false),
        }
    }

    /// Leaves the last frame right below the output, with the cursor below
    /// it, as the terminal's own output would. Always redrawn, since the
    /// terminal may have echoed the keys that ended the run, such as `^C`,
    /// onto it, and in full: it's not redrawn again, so what runs past the
    /// top of a short screen can stay in the scrollback.
    pub fn finish(
        &mut self,
        printed: Option<&str>,
        state: &State,
        now: f64,
        tick: usize,
        size: Size,
    ) -> io::Result<()> {
        let lines = render::frame(state, now, tick, size.width, u16::MAX, self.palette);
        self.draw(printed, lines, size, true)?;
        self.out.write_all(b"\x1b[?25h")?;
        self.out.flush()
    }

    pub fn hide_cursor(&mut self) -> io::Result<()> {
        self.out.write_all(b"\x1b[?25l")?;
        self.out.flush()
    }
}

/// The rows `text` takes printed at `width`, its escape sequences taking none.
fn rows(text: &str, width: u16) -> usize {
    text.split('\n')
        .map(|line| {
            let mut columns = 0;
            let mut chars = line.chars();
            while let Some(c) = chars.next() {
                if c == '\x1b' {
                    // CSI ends at its final byte, OSC at BEL or ST.
                    match chars.next() {
                        Some('[') => {
                            for c in chars.by_ref() {
                                if ('@'..='~').contains(&c) {
                                    break;
                                }
                            }
                        }
                        Some(']') => {
                            while let Some(c) = chars.next() {
                                if c == '\x07' || (c == '\x1b' && chars.next().is_some()) {
                                    break;
                                }
                            }
                        }
                        _ => {}
                    }
                } else {
                    columns += unicode_width::UnicodeWidthChar::width(c).unwrap_or(0);
                }
            }
            columns.div_ceil(width.max(1) as usize).max(1)
        })
        .sum()
}

const BEGIN_SYNCHRONIZED_UPDATE: &[u8] = b"\x1b[?2026h";
const END_SYNCHRONIZED_UPDATE: &[u8] = b"\x1b[?2026l";

fn color_code(color: Color, background: bool) -> Option<String> {
    let offset = if background { 10 } else { 0 };
    let named = |code: u8| Some((code + offset).to_string());
    match color {
        Color::Reset => None,
        Color::Black => named(30),
        Color::Red => named(31),
        Color::Green => named(32),
        Color::Yellow => named(33),
        Color::Blue => named(34),
        Color::Magenta => named(35),
        Color::Cyan => named(36),
        Color::Gray => named(37),
        Color::DarkGray => named(90),
        Color::LightRed => named(91),
        Color::LightGreen => named(92),
        Color::LightYellow => named(93),
        Color::LightBlue => named(94),
        Color::LightMagenta => named(95),
        Color::LightCyan => named(96),
        Color::White => named(97),
        Color::Indexed(index) => Some(format!("{};5;{index}", 38 + offset)),
        Color::Rgb(r, g, b) => Some(format!("{};2;{r};{g};{b}", 38 + offset)),
    }
}

fn sgr(style: Style) -> Vec<u8> {
    let mut codes = vec!["0".to_string()];
    for (modifier, code) in [
        (Modifier::BOLD, "1"),
        (Modifier::DIM, "2"),
        (Modifier::ITALIC, "3"),
        (Modifier::UNDERLINED, "4"),
        (Modifier::REVERSED, "7"),
        (Modifier::CROSSED_OUT, "9"),
    ] {
        if style.add_modifier.contains(modifier) {
            codes.push(code.to_string());
        }
    }
    codes.extend(style.fg.and_then(|color| color_code(color, false)));
    codes.extend(style.bg.and_then(|color| color_code(color, true)));
    format!("\x1b[{}m", codes.join(";")).into_bytes()
}

fn encode(buf: &mut Vec<u8>, line: &Line) {
    let mut current = Style::new();
    for span in &line.spans {
        let style = line.style.patch(span.style);
        if style != current {
            buf.extend(sgr(style));
            current = style;
        }
        buf.extend(span.content.as_bytes());
    }
    if current != Style::new() {
        buf.extend(b"\x1b[0m");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tui::render::ColorLevel;
    use crate::tui::state::{Messages, TuiChain, TuiInfo};
    use crate::tui::testing::Emulator;

    const SIZE: Size = Size {
        width: 60,
        height: 30,
    };

    fn state() -> State {
        let mut state = State::new(TuiInfo {
            start_time: 0.,
            graphql_url: "http://localhost:8080".to_string(),
            ..TuiInfo::default()
        });
        state.update(
            &[TuiChain {
                chain_id: "1".to_string(),
                powered_by_hyper_sync: true,
                start_block: 0,
                end_block: Some(100),
                first_event_block_number: Some(0),
                progress_block_number: 100,
                processed_to_endblock: true,
                latest_fetched_block_number: 100,
                known_height: 100,
                source_block_number: 100,
                timestamp_caught_up_to_head_or_endblock: Some(3_000.),
                num_events_processed: 42.,
                ..TuiChain::default()
            }],
            0.,
        );
        state
    }

    const TITLE: [&str; 2] = ["  envio", ""];

    const STATUS: [&str; 5] = [
        "  Chain 1 ━━━━━━━━━━━━━━━━━━━━━━  ✓  at end 100 42 events",
        "",
        "  ✓ synced in 3s · 42 events",
        "",
        "  GraphQL http://localhost:8080",
    ];

    /// The title, the logo centred over the rows with a blank row below, and the status.
    fn frame() -> Vec<String> {
        let logo = crate::tui::logo::lines(0, |_| ratatui::style::Color::Reset)
            .iter()
            .map(|line| format!("{:17}{}", "", line).trim_end().to_string())
            .chain(std::iter::once(String::new()))
            .collect::<Vec<_>>();
        TITLE
            .iter()
            .map(|line| line.to_string())
            .chain(logo)
            .chain(STATUS.iter().map(|line| line.to_string()))
            .collect()
    }

    fn with_frame(before: &[&str]) -> Vec<String> {
        before
            .iter()
            .map(|line| line.to_string())
            .chain(frame())
            .collect()
    }

    /// After what scrolled off, blank rows, then `above`, the frame and
    /// `below` it, pinned to the bottom of a `SIZE` screen.
    fn pinned(scrolled: &[&str], above: &[&str], below: &[&str]) -> Vec<String> {
        let blank = SIZE.height as usize - 1 - above.len() - frame().len() - below.len();
        scrolled
            .iter()
            .map(|line| line.to_string())
            .chain(std::iter::repeat_n(String::new(), blank))
            .chain(above.iter().map(|line| line.to_string()))
            .chain(frame())
            .chain(below.iter().map(|line| line.to_string()))
            .collect()
    }

    #[test]
    fn takes_the_screen_and_prints_above_the_frame_pinned_to_the_bottom() {
        let emulator = Emulator::new(SIZE);
        emulator.clone().write_all(b"$ envio dev\r\n").unwrap();
        let mut session = emulator.session();
        session.render(None, &state(), 0., 0, SIZE).unwrap();
        session
            .render(Some("first log\nsecond log"), &state(), 0., 0, SIZE)
            .unwrap();
        assert_eq!(
            emulator.lines(),
            pinned(&["$ envio dev"], &["first log", "second log"], &[])
        );
    }

    // Startup logs would otherwise scroll off with whatever the shell showed.
    #[test]
    fn keeps_what_the_terminal_showed_right_above_the_frame() {
        let emulator = Emulator::new(SIZE);
        emulator
            .clone()
            .write_all(b"$ envio dev\r\nstarting\r\nhalf a line")
            .unwrap();
        let mut session = emulator.session();
        session.started_at(emulator.cursor());
        session.render(None, &state(), 0., 0, SIZE).unwrap();
        session
            .render(Some("first log"), &state(), 0., 0, SIZE)
            .unwrap();
        assert_eq!(
            emulator.lines(),
            pinned(
                &[],
                &["$ envio dev", "starting", "half a line", "first log"],
                &[]
            )
        );
    }

    #[test]
    fn stays_pinned_to_the_bottom_of_a_taller_terminal() {
        let short = Size {
            width: 60,
            height: 20,
        };
        let emulator = Emulator::new(SIZE);
        let mut session = emulator.session();
        session.render(None, &state(), 0., 0, short).unwrap();
        session.render(None, &state(), 0., 0, SIZE).unwrap();
        assert_eq!(emulator.lines(), pinned(&[], &[], &[]));
    }

    #[test]
    fn keeps_printed_lines_in_scrollback_once_the_screen_fills() {
        let size = Size {
            width: 60,
            height: 16,
        };
        let emulator = Emulator::new(size);
        let mut session = emulator.session();
        session.render(None, &state(), 0., 0, size).unwrap();
        let printed: Vec<String> = (1..=10).map(|i| format!("log {i}")).collect();
        for line in &printed {
            session.render(Some(line), &state(), 0., 0, size).unwrap();
        }
        let printed: Vec<&str> = printed.iter().map(String::as_str).collect();
        assert_eq!(emulator.lines(), with_frame(&printed));
    }

    #[test]
    fn keeps_a_trailing_newline_as_a_blank_line() {
        let emulator = Emulator::new(SIZE);
        let mut session = emulator.session();
        session
            .render(Some("pretty log\n"), &state(), 0., 0, SIZE)
            .unwrap();
        assert_eq!(emulator.lines(), pinned(&[], &["pretty log", ""], &[]));
    }

    #[test]
    fn redraws_cleanly_when_the_frame_grows_and_shrinks() {
        let emulator = Emulator::new(SIZE);
        let mut session = emulator.session();
        let mut state = state();
        session.render(None, &state, 0., 0, SIZE).unwrap();
        state.messages = Messages::Failed;
        session.render(None, &state, 0., 0, SIZE).unwrap();
        let grown = emulator.lines();
        state.messages = Messages::Loaded(vec![]);
        session.render(None, &state, 0., 0, SIZE).unwrap();
        assert_eq!(
            (grown, emulator.lines()),
            (
                pinned(
                    &[],
                    &[],
                    &["", "  ▲ Failed to load messages from envio server"]
                ),
                pinned(&[], &[], &[])
            )
        );
    }

    #[test]
    fn erases_a_frame_the_terminal_rewrapped_when_it_narrowed() {
        let narrow = Size {
            width: 40,
            height: 30,
        };
        let emulator = Emulator::new(SIZE);
        let mut session = emulator.session();
        session.render(None, &state(), 0., 0, SIZE).unwrap();
        // Replays the wide screen onto a narrow one, wrapping its long rows the
        // way a reflowing terminal does when it narrows: the cursor's row stays
        // at the bottom and the rows above make way upwards.
        let rows: Vec<String> = emulator
            .parser
            .lock()
            .unwrap()
            .screen()
            .rows(0, SIZE.width)
            .flat_map(|row| {
                let chars: Vec<char> = row.trim_end().chars().collect();
                if chars.is_empty() {
                    vec![String::new()]
                } else {
                    chars
                        .chunks(narrow.width as usize)
                        .map(|chunk| chunk.iter().collect())
                        .collect()
                }
            })
            .collect();
        let replayed = Emulator::new(narrow);
        replayed
            .clone()
            .write_all(rows.join("\r\n").as_bytes())
            .unwrap();
        session.out = replayed.clone();
        session.render(None, &state(), 0., 0, narrow).unwrap();

        let fresh = Emulator::new(narrow);
        fresh
            .session()
            .render(None, &state(), 0., 0, narrow)
            .unwrap();
        assert_eq!(replayed.screen_text(), fresh.screen_text());
    }

    #[test]
    fn drops_the_logo_before_the_status_on_a_short_screen() {
        let render_at = |height| {
            let size = Size { width: 60, height };
            let emulator = Emulator::new(size);
            let mut session = emulator.session();
            session.render(None, &state(), 0., 0, size).unwrap();
            session.render(Some("log"), &state(), 0., 0, size).unwrap();
            emulator.lines()
        };
        let status = |rows: usize| -> Vec<String> {
            ["log"]
                .into_iter()
                .chain(TITLE.into_iter().chain(STATUS).take(rows))
                .map(str::to_string)
                .collect()
        };
        // Then the blank lines between sections, before any content.
        let compact: Vec<String> = ["log", TITLE[0], STATUS[0], STATUS[2], STATUS[4]]
            .map(str::to_string)
            .to_vec();
        assert_eq!((render_at(9), render_at(6)), (status(7), compact));
    }

    // It's no longer redrawn, so nothing stops it running past the top of
    // the screen into the scrollback, where it stays to scroll back to.
    #[test]
    fn prints_the_whole_final_frame_on_a_short_screen() {
        let size = Size {
            width: 60,
            height: 6,
        };
        let emulator = Emulator::new(size);
        let mut session = emulator.session();
        session.render(None, &state(), 0., 0, size).unwrap();
        session.finish(None, &state(), 0., 0, size).unwrap();
        assert_eq!(emulator.lines(), frame());
    }

    #[test]
    fn rewrites_only_the_lines_that_changed() {
        // Without colour, so the logo's flow doesn't change the frame too.
        let emulator = Emulator::new(SIZE);
        let mut session = emulator.session_with(ColorLevel::None);
        let mut calculating = State::new(TuiInfo {
            graphql_url: "http://localhost:8080".to_string(),
            ..TuiInfo::default()
        });
        calculating.update(
            &[TuiChain {
                chain_id: "1".to_string(),
                ..TuiChain::default()
            }],
            0.,
        );
        session.render(None, &calculating, 0., 0, SIZE).unwrap();
        let before = emulator.written();
        session.render(None, &calculating, 0., 1, SIZE).unwrap();
        let spinner_tick = emulator.written() - before;

        let fresh = Emulator::new(SIZE);
        fresh
            .session_with(ColorLevel::None)
            .render(None, &calculating, 0., 1, SIZE)
            .unwrap();
        assert_eq!(
            (emulator.lines(), spinner_tick < 100),
            (fresh.lines(), true)
        );
    }

    #[test]
    fn keeps_colours_of_printed_lines() {
        let emulator = Emulator::new(SIZE);
        let mut session = emulator.session();
        session
            .render(Some("\x1b[31mERROR\x1b[39m: boom"), &state(), 0., 0, SIZE)
            .unwrap();
        let row = SIZE.height - 1 - frame().len() as u16 - 1;
        let parser = emulator.parser.lock().unwrap();
        let cell = |col| parser.screen().cell(row, col).unwrap().fgcolor();
        assert_eq!(
            (cell(0), cell(5)),
            (vt100::Color::Idx(1), vt100::Color::Default)
        );
    }

    #[test]
    fn assumes_a_size_the_terminal_did_not_report() {
        assert_eq!(
            (Size::reported(0, 0), Size::reported(120, 40)),
            (
                Size {
                    width: 80,
                    height: u16::MAX
                },
                Size {
                    width: 120,
                    height: 40
                }
            )
        );
    }

    #[test]
    fn encodes_styles_as_sgr_sequences() {
        let mut buf = Vec::new();
        encode(
            &mut buf,
            &Line::from(vec![
                ratatui::text::Span::raw("plain "),
                ratatui::text::Span::styled(
                    "bar",
                    Style::new()
                        .fg(Color::DarkGray)
                        .bg(Color::Rgb(255, 187, 47))
                        .add_modifier(Modifier::BOLD),
                ),
            ]),
        );
        assert_eq!(
            String::from_utf8(buf).unwrap(),
            "plain \x1b[0;1;90;48;2;255;187;47mbar\x1b[0m"
        );
    }

    #[test]
    fn redraws_the_final_frame_over_what_the_terminal_echoed() {
        let emulator = Emulator::new(SIZE);
        let mut session = emulator.session();
        session.render(None, &state(), 0., 0, SIZE).unwrap();
        emulator.clone().write_all(b"^C").unwrap();
        session.finish(None, &state(), 0., 0, SIZE).unwrap();
        assert_eq!(emulator.lines(), with_frame(&[]));
    }

    #[test]
    fn leaves_the_final_frame_with_the_cursor_below_it() {
        let emulator = Emulator::new(SIZE);
        let mut session = emulator.session();
        session.hide_cursor().unwrap();
        session.render(None, &state(), 0., 0, SIZE).unwrap();
        session.finish(None, &state(), 0., 0, SIZE).unwrap();
        let hidden = emulator.parser.lock().unwrap().screen().hide_cursor();
        assert_eq!(
            (emulator.lines(), emulator.cursor(), hidden),
            (with_frame(&[]), (frame().len() as u16, 0), false)
        );
    }
}
