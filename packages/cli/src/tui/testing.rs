//! A terminal emulator for tests to draw into, and snapshots of what it shows:
//! the screen as text, for a line diff, and as an SVG, for a reviewer to look
//! at in the pull request.

use super::logo;
use super::render::{ColorLevel, Palette};
use super::session::{Session, Size};
use std::{
    fmt::Write as _,
    io::{self, Write},
    sync::{Arc, Mutex},
};

#[derive(Clone)]
pub struct Emulator {
    pub parser: Arc<Mutex<vt100::Parser>>,
    written: Arc<Mutex<usize>>,
}

impl Write for Emulator {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.parser.lock().unwrap().process(buf);
        *self.written.lock().unwrap() += buf.len();
        Ok(buf.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Emulator {
    pub fn new(size: Size) -> Self {
        Emulator {
            parser: Arc::new(Mutex::new(vt100::Parser::new(
                size.height,
                size.width,
                1000,
            ))),
            written: Arc::new(Mutex::new(0)),
        }
    }

    pub fn written(&self) -> usize {
        *self.written.lock().unwrap()
    }

    /// Scrollback followed by the screen, trailing blanks trimmed.
    pub fn lines(&self) -> Vec<String> {
        let mut parser = self.parser.lock().unwrap();
        parser.screen_mut().set_scrollback(usize::MAX);
        let scrolled = parser.screen().scrollback();
        let (rows, cols) = parser.screen().size();
        let mut lines: Vec<String> = parser
            .screen()
            .rows(0, cols)
            .take(scrolled.min(rows as usize))
            .collect();
        parser.screen_mut().set_scrollback(0);
        lines.extend(parser.screen().rows(0, cols));
        while lines.last().is_some_and(|line| line.trim().is_empty()) {
            lines.pop();
        }
        lines
            .iter()
            .map(|line| line.trim_end().to_string())
            .collect()
    }

    /// The screen as text, without the colours.
    pub fn screen_text(&self) -> Vec<String> {
        let parser = self.parser.lock().unwrap();
        let mut lines: Vec<String> = parser
            .screen()
            .rows(0, parser.screen().size().1)
            .map(|line| line.trim_end().to_string())
            .collect();
        while lines.last().is_some_and(|line| line.is_empty()) {
            lines.pop();
        }
        lines
    }

    pub fn cursor(&self) -> (u16, u16) {
        self.parser.lock().unwrap().screen().cursor_position()
    }

    pub fn session(&self) -> Session<Emulator> {
        self.session_with(ColorLevel::TrueColor)
    }

    pub fn session_with(&self, level: ColorLevel) -> Session<Emulator> {
        Session::new(self.clone(), Palette { level })
    }

    /// The screen as a dark-themed terminal would draw it.
    pub fn svg(&self) -> String {
        let parser = self.parser.lock().unwrap();
        let screen = parser.screen();
        let (rows, cols) = screen.size();
        let rows = (0..rows)
            .rev()
            .find(|row| {
                (0..cols).any(|col| {
                    screen.cell(*row, col).is_some_and(|cell| {
                        !cell.contents().trim().is_empty()
                            || cell.inverse()
                            || cell.bgcolor() != vt100::Color::Default
                    })
                })
            })
            .map_or(1, |row| row + 1);
        let mut shapes = String::new();
        for row in 0..rows {
            for col in 0..cols {
                let Some(cell) = screen.cell(row, col) else {
                    continue;
                };
                if cell.is_wide_continuation() {
                    continue;
                }
                let (x, y) = (col as u32 * CELL_WIDTH, row as u32 * CELL_HEIGHT);
                let width = CELL_WIDTH * if cell.is_wide() { 2 } else { 1 };
                let (mut fg, mut bg) = (
                    color(cell.fgcolor()).unwrap_or_else(|| FOREGROUND.to_string()),
                    color(cell.bgcolor()),
                );
                if cell.inverse() {
                    (fg, bg) = (bg.unwrap_or_else(|| BACKGROUND.to_string()), Some(fg));
                }
                if let Some(bg) = bg {
                    rect(&mut shapes, x, y, width, CELL_HEIGHT, &bg);
                }
                let text = cell.contents();
                let braille = text
                    .chars()
                    .next()
                    .map(|c| c as u32)
                    .filter(|c| (0x2801..=0x28FF).contains(c));
                if let Some(dots) = braille {
                    // Braille and line glyphs as shapes, the way terminals
                    // that draw them themselves show them.
                    for (dy, bits) in logo::DOTS.iter().enumerate() {
                        for (dx, bit) in bits.iter().enumerate() {
                            if (dots - 0x2800) & bit != 0 {
                                let _ = writeln!(
                                    shapes,
                                    r#"<circle cx="{}" cy="{}" r="1.4" fill="{fg}"/>"#,
                                    x + 3 + dx as u32 * 4,
                                    y + 3 + dy as u32 * 4 + dy as u32 / 2,
                                );
                            }
                        }
                    }
                } else if text == "━" || text == "─" {
                    let thickness = if text == "━" { 4 } else { 2 };
                    rect(
                        &mut shapes,
                        x,
                        y + (CELL_HEIGHT - thickness) / 2,
                        width,
                        thickness,
                        &fg,
                    );
                } else if !text.trim().is_empty() {
                    let weight = if cell.bold() {
                        r#" font-weight="bold""#
                    } else {
                        ""
                    };
                    let underline = if cell.underline() {
                        r#" text-decoration="underline""#
                    } else {
                        ""
                    };
                    let text = text
                        .replace('&', "&amp;")
                        .replace('<', "&lt;")
                        .replace('>', "&gt;");
                    let _ = writeln!(
                        shapes,
                        r#"<text x="{x}" y="{}" fill="{fg}"{weight}{underline}>{text}</text>"#,
                        y + CELL_HEIGHT - 5
                    );
                }
            }
        }
        format!(
            r#"<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" font-family="ui-monospace, Menlo, Consolas, monospace" font-size="16" xml:space="preserve" shape-rendering="crispEdges">
<rect width="100%" height="100%" fill="{BACKGROUND}"/>
{shapes}</svg>
"#,
            w = cols as u32 * CELL_WIDTH,
            h = rows as u32 * CELL_HEIGHT,
        )
    }
}

const CELL_WIDTH: u32 = 10;
const CELL_HEIGHT: u32 = 20;
const FOREGROUND: &str = "#cccccc";
const BACKGROUND: &str = "#1e1e1e";

fn rect(shapes: &mut String, x: u32, y: u32, width: u32, height: u32, fill: &str) {
    let _ = writeln!(
        shapes,
        r#"<rect x="{x}" y="{y}" width="{width}" height="{height}" fill="{fill}"/>"#
    );
}

/// VS Code's dark theme for the 16 standard colours, and xterm's for the rest.
fn color(color: vt100::Color) -> Option<String> {
    const ANSI: [&str; 16] = [
        "#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5",
        "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#ffffff",
    ];
    match color {
        vt100::Color::Default => None,
        vt100::Color::Rgb(r, g, b) => Some(format!("#{r:02x}{g:02x}{b:02x}")),
        vt100::Color::Idx(index) if index < 16 => Some(ANSI[index as usize].to_string()),
        vt100::Color::Idx(index) if index >= 232 => {
            let level = 8 + (index - 232) * 10;
            Some(format!("#{level:02x}{level:02x}{level:02x}"))
        }
        vt100::Color::Idx(index) => {
            let level = |n: u8| if n == 0 { 0 } else { 55 + n * 40 };
            let cube = index - 16;
            Some(format!(
                "#{:02x}{:02x}{:02x}",
                level(cube / 36),
                level(cube / 6 % 6),
                level(cube % 6)
            ))
        }
    }
}

/// Asserts the screen against `<name>.snap`, as text, and against
/// `<name>_screen.snap.svg`, as an image. Each binary snapshot keeps its
/// metadata in a `.snap` of its own, hence the separate name.
pub fn assert_screen(name: &str, emulator: &Emulator) {
    insta::assert_snapshot!(name, emulator.screen_text().join("\n"));
    insta::assert_binary_snapshot!(&format!("{name}_screen.svg"), emulator.svg().into_bytes());
}
