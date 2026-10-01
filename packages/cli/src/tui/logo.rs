use ratatui::{
    style::{Color, Style},
    text::{Line, Span},
};

// The brand wordmark traced from the brand kit's SVG at 50×6, two by two
// pixels per cell.
const BITMAP: [&str; 6] = [
    "########..###.....##..###.....##..###....######...",
    "###.......####....##...##....###..###..###....###.",
    "#######...######..##...###..###...###.###......###",
    "###.......###.######....###.##....###.###......###",
    "###.......###...####.....#####....###..###....###.",
    "########..###....###.....####.....###....######...",
];

/// Indexed by the lit pixels of a cell: top left, top right, bottom left,
/// bottom right, from the lowest bit.
pub const QUADRANTS: [&str; 16] = [
    " ", "▘", "▝", "▀", "▖", "▌", "▞", "▛", "▗", "▚", "▐", "▜", "▄", "▙", "▟", "█",
];

const GRADIENT: [(u8, u8, u8); 3] = [(0xFF, 0x82, 0x67), (0xFF, 0xA1, 0x52), (0xFD, 0xD7, 0x00)];

pub fn width() -> usize {
    BITMAP[0].len() / 2
}

fn gradient(position: f64) -> (u8, u8, u8) {
    let scaled = position.clamp(0., 1.) * (GRADIENT.len() - 1) as f64;
    let index = (scaled.floor() as usize).min(GRADIENT.len() - 2);
    let t = scaled - index as f64;
    let (from, to) = (GRADIENT[index], GRADIENT[index + 1]);
    let mix = |a: u8, b: u8| (a as f64 + (b as f64 - a as f64) * t).round() as u8;
    (mix(from.0, to.0), mix(from.1, to.1), mix(from.2, to.2))
}

fn lit(row: usize, column: usize) -> bool {
    BITMAP[row].as_bytes()[column] == b'#'
}

/// Cells with more than a corner lit are drawn in reverse video: the lit part
/// is the cell's background, which terminals paint as a solid rectangle, and
/// the unlit part is the glyph. Many terminals leave a hairline gap where a
/// block glyph meets its neighbour; this way the gap falls in the dark around
/// a letter rather than through its strokes.
pub fn lines(rgb: impl Fn((u8, u8, u8)) -> Color) -> Vec<Line<'static>> {
    let columns = width();
    (0..BITMAP.len() / 2)
        .map(|row| {
            Line::from(
                (0..columns)
                    .map(|column| {
                        let pixels = (0..4).fold(0, |pixels, bit| {
                            let lit = lit(row * 2 + bit / 2, column * 2 + bit % 2);
                            pixels | (usize::from(lit) << bit)
                        });
                        let style =
                            Style::new().fg(rgb(gradient(column as f64 / (columns - 1) as f64)));
                        if pixels.count_ones() >= 2 {
                            Span::styled(QUADRANTS[!pixels & 0b1111], style.reversed())
                        } else {
                            Span::styled(QUADRANTS[pixels], style)
                        }
                    })
                    .collect::<Vec<_>>(),
            )
        })
        .collect()
}

/// For a terminal too narrow for the wordmark.
pub fn compact(rgb: impl Fn((u8, u8, u8)) -> Color) -> Line<'static> {
    let text = "ENVIO";
    let last = (text.len() - 1) as f64;
    Line::from(
        text.chars()
            .enumerate()
            .map(|(i, c)| {
                Span::styled(
                    c.to_string(),
                    Style::new().fg(rgb(gradient(i as f64 / last))).bold(),
                )
            })
            .collect::<Vec<_>>(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::style::Modifier;

    /// The pixels a terminal shows for the drawn cells.
    fn shown(lines: &[Line]) -> Vec<String> {
        let mut rows = vec![String::new(); lines.len() * 2];
        for (row, line) in lines.iter().enumerate() {
            for span in &line.spans {
                let glyph = QUADRANTS
                    .iter()
                    .position(|quadrant| *quadrant == span.content)
                    .unwrap();
                let reversed = span.style.add_modifier.contains(Modifier::REVERSED);
                let pixels = if reversed { !glyph & 0b1111 } else { glyph };
                for bit in 0..4 {
                    rows[row * 2 + bit / 2].push(if pixels & (1 << bit) != 0 { '#' } else { '.' });
                }
            }
        }
        rows
    }

    #[test]
    fn draws_the_traced_wordmark_with_quadrants() {
        let lines = lines(|(r, g, b)| Color::Rgb(r, g, b));
        assert_eq!(
            (
                shown(&lines),
                lines.iter().map(Line::width).collect::<Vec<_>>()
            ),
            (BITMAP.map(str::to_string).to_vec(), vec![25, 25, 25])
        );
    }

    #[test]
    fn paints_fully_lit_cells_as_background() {
        let first = lines(|(r, g, b)| Color::Rgb(r, g, b))[0].spans[0].clone();
        assert_eq!(
            first,
            Span::styled(
                " ",
                Style::new().fg(Color::Rgb(0xFF, 0x82, 0x67)).reversed()
            )
        );
    }

    #[test]
    fn runs_the_brand_gradient_across_the_wordmark() {
        assert_eq!(
            (gradient(0.), gradient(0.5), gradient(1.)),
            ((0xFF, 0x82, 0x67), (0xFF, 0xA1, 0x52), (0xFD, 0xD7, 0x00))
        );
    }
}
