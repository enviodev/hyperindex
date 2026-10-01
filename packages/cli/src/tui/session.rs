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
}

/// The display drawn below the terminal's output. It only ever moves the
/// cursor relative to where it left it, so it never has to ask the terminal
/// where that is, and printed lines scroll off the top the way any output
/// does, into the terminal's own scrollback.
pub struct Session<W: Write> {
    out: W,
    palette: Palette,
    /// The frame on screen, kept to erase it and to skip redrawing it as is.
    drawn: Vec<Line<'static>>,
    drawn_width: u16,
}

impl<W: Write> Session<W> {
    pub fn new(out: W, palette: Palette) -> Self {
        Session {
            out,
            palette,
            drawn: Vec::new(),
            drawn_width: 0,
        }
    }

    /// Moves the cursor back to where the frame started and clears from there.
    fn erase(&self, buf: &mut Vec<u8>, width: u16) {
        if self.drawn.is_empty() {
            return;
        }
        // A narrower terminal may have rewrapped the frame's lines onto more rows.
        let rows: usize = if width < self.drawn_width {
            self.drawn
                .iter()
                .map(|line| line.width().div_ceil(width.max(1) as usize).max(1))
                .sum()
        } else {
            self.drawn.len()
        };
        buf.push(b'\r');
        if rows > 1 {
            buf.extend(format!("\x1b[{}A", rows - 1).as_bytes());
        }
        buf.extend(b"\x1b[J");
    }

    fn frame(&self, state: &State, now: f64, tick: usize, size: Size) -> Vec<Line<'static>> {
        // Rows that scroll off the top can't be erased, so they'd pile up in
        // the scrollback on every redraw.
        let height = size.height.saturating_sub(1).max(1);
        render::frame(state, now, tick, size.width, height, self.palette)
    }

    /// Rewrites the rows that differ from the frame on screen in place, with
    /// the cursor left on the last row as a full redraw leaves it.
    fn patch(&self, buf: &mut Vec<u8>, lines: &[Line<'static>]) {
        let last = lines.len() - 1;
        let mut row = last;
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
        if row < last {
            buf.extend(format!("\x1b[{}B", last - row).as_bytes());
        }
    }

    /// Prints `printed` above the display and redraws it, as one synchronized
    /// update so terminals that support it never show the display erased.
    fn draw(
        &mut self,
        printed: Option<&str>,
        lines: Vec<Line<'static>>,
        size: Size,
        in_place: bool,
    ) -> io::Result<()> {
        let mut buf = BEGIN_SYNCHRONIZED_UPDATE.to_vec();
        if in_place {
            self.patch(&mut buf, &lines);
        } else {
            self.erase(&mut buf, size.width);
            if let Some(text) = printed {
                buf.extend(text.replace('\n', "\r\n").as_bytes());
                buf.extend(b"\x1b[0m\r\n");
            }
            for (i, line) in lines.iter().enumerate() {
                if i > 0 {
                    buf.extend(b"\r\n");
                }
                encode(&mut buf, line);
            }
        }
        buf.extend(END_SYNCHRONIZED_UPDATE);
        self.out.write_all(&buf)?;
        self.out.flush()?;
        self.drawn = lines;
        self.drawn_width = size.width;
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
        let same_shape = size.width == self.drawn_width && lines.len() == self.drawn.len();
        match printed {
            None if same_shape && lines == self.drawn => Ok(()),
            None if same_shape => self.draw(None, lines, size, true),
            _ => self.draw(printed, lines, size, false),
        }
    }

    /// Leaves the last frame on screen with the cursor below it, as the
    /// terminal's own output would. Always redrawn, since the terminal may
    /// have echoed the keys that ended the run, such as `^C`, onto it.
    pub fn finish(
        &mut self,
        printed: Option<&str>,
        state: &State,
        now: f64,
        tick: usize,
        size: Size,
    ) -> io::Result<()> {
        let lines = self.frame(state, now, tick, size);
        self.draw(printed, lines, size, false)?;
        self.out.write_all(b"\r\n\x1b[?25h")?;
        self.out.flush()
    }

    pub fn hide_cursor(&mut self) -> io::Result<()> {
        self.out.write_all(b"\x1b[?25l")?;
        self.out.flush()
    }
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
        "  Chain 1 ━━━━━━━━━━━━━━━━━━━━━━━  ✓  at end 100 42 events",
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

    #[test]
    fn draws_below_the_existing_output_and_prints_above_the_frame() {
        let emulator = Emulator::new(SIZE);
        emulator.clone().write_all(b"$ envio dev\r\n").unwrap();
        let mut session = emulator.session();
        session.render(None, &state(), 0., 0, SIZE).unwrap();
        session
            .render(Some("first log\nsecond log"), &state(), 0., 0, SIZE)
            .unwrap();
        assert_eq!(
            emulator.lines(),
            with_frame(&["$ envio dev", "first log", "second log"])
        );
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
        assert_eq!(emulator.lines(), with_frame(&["pretty log", ""]));
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
                with_frame(&[])
                    .into_iter()
                    .chain([
                        "".to_string(),
                        "  ▲ Failed to load messages from envio server".to_string()
                    ])
                    .collect::<Vec<_>>(),
                with_frame(&[])
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
        // Replays the wide frame onto a narrow screen, which wraps its long
        // rows the way a reflowing terminal does when it narrows.
        let replayed = Emulator::new(narrow);
        let screen = emulator.parser.lock().unwrap().screen().contents();
        replayed
            .clone()
            .write_all(format!("$ envio dev\r\n{}", screen.replace('\n', "\r\n")).as_bytes())
            .unwrap();
        session.out = replayed.clone();
        session.render(None, &state(), 0., 0, narrow).unwrap();

        let fresh = Emulator::new(narrow);
        fresh.clone().write_all(b"$ envio dev\r\n").unwrap();
        fresh
            .session()
            .render(None, &state(), 0., 0, narrow)
            .unwrap();
        assert_eq!(replayed.lines(), fresh.lines());
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
        assert_eq!((render_at(9), render_at(6)), (status(7), status(5)));
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
        let parser = emulator.parser.lock().unwrap();
        let cell = |col| parser.screen().cell(0, col).unwrap().fgcolor();
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
