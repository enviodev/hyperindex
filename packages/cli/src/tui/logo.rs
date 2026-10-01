use ratatui::{
    style::{Color, Style},
    text::{Line, Span},
};

// The brand wordmark traced from the brand kit's SVG at 52×12, drawn as
// every other pixel so it reads as dots, two by four pixels per braille cell.
const BITMAP: [&str; 12] = [
    "########..###.....###..##......###.###.....#####....",
    "########..####....###..###.....###.###....########..",
    "###.......#####...###..###....###..###...####.#####.",
    "###.......#####...###...##....###..###..###.....###.",
    "###.......######..###...###...##...###..###......###",
    "########..#######.###...###..###...###..###......###",
    "########..###.#######....##..###...###..###......###",
    "###.......###..######....###.##....###..###......###",
    "###.......###...#####.....#####....###..###.....###.",
    "########..###....####.....####.....###...##########.",
    "#########.###.....###.....####.....###....########..",
    "#########.###......##......###.....###.....#####....",
];

/// The braille dot for the pixel at `[row][column]` of a cell.
pub const DOTS: [[u32; 2]; 4] = [[0x01, 0x08], [0x02, 0x10], [0x04, 0x20], [0x40, 0x80]];

const GRADIENT: [(u8, u8, u8); 3] = [(0xFF, 0x82, 0x67), (0xFF, 0xA1, 0x52), (0xFD, 0xD7, 0x00)];

/// Ticks for the colours to flow once across the wordmark and back.
const FLOW_TICKS: f64 = 40.;

/// The cell under the point of the V.
pub const V_POINT: usize = 14;

pub fn width() -> usize {
    BITMAP[0].len() / 2
}

pub fn gradient(position: f64) -> (u8, u8, u8) {
    let scaled = position.clamp(0., 1.) * (GRADIENT.len() - 1) as f64;
    let index = (scaled.floor() as usize).min(GRADIENT.len() - 2);
    let t = scaled - index as f64;
    let (from, to) = (GRADIENT[index], GRADIENT[index + 1]);
    let mix = |a: u8, b: u8| (a as f64 + (b as f64 - a as f64) * t).round() as u8;
    (mix(from.0, to.0), mix(from.1, to.1), mix(from.2, to.2))
}

/// Coral to gold and back, so the gradient can keep flowing without a seam.
fn flowing(position: f64) -> (u8, u8, u8) {
    let x = position.rem_euclid(1.) * 2.;
    gradient(if x <= 1. { x } else { 2. - x })
}

fn lit(row: usize, column: usize) -> bool {
    BITMAP[row].as_bytes()[column] == b'#' && (row + column).is_multiple_of(2)
}

pub fn lines(tick: usize, rgb: impl Fn((u8, u8, u8)) -> Color) -> Vec<Line<'static>> {
    let columns = width();
    let phase = tick as f64 / FLOW_TICKS;
    (0..BITMAP.len() / 4)
        .map(|row| {
            Line::from(
                (0..columns)
                    .map(|column| {
                        let mut dots = 0;
                        for (y, bits) in DOTS.iter().enumerate() {
                            for (x, bit) in bits.iter().enumerate() {
                                if lit(row * 4 + y, column * 2 + x) {
                                    dots |= bit;
                                }
                            }
                        }
                        if dots == 0 {
                            return Span::raw(" ");
                        }
                        let position = column as f64 / (columns - 1) as f64;
                        Span::styled(
                            char::from_u32(0x2800 + dots).unwrap().to_string(),
                            Style::new().fg(rgb(flowing(position / 2. - phase))),
                        )
                    })
                    .collect::<Vec<_>>(),
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The pixels the braille dots show.
    fn shown(lines: &[Line]) -> Vec<String> {
        let mut rows = vec![String::new(); lines.len() * 4];
        for (row, line) in lines.iter().enumerate() {
            for span in &line.spans {
                let dots = span.content.chars().next().unwrap() as u32;
                let dots = dots.saturating_sub(0x2800);
                for x in 0..2 {
                    for (y, bits) in DOTS.iter().enumerate() {
                        rows[row * 4 + y].push(if dots & bits[x] != 0 { '#' } else { '.' });
                    }
                }
            }
        }
        rows
    }

    #[test]
    fn dots_every_other_pixel_of_the_wordmark() {
        let lines = lines(0, |(r, g, b)| Color::Rgb(r, g, b));
        let expected: Vec<String> = BITMAP
            .iter()
            .enumerate()
            .map(|(row, pixels)| {
                (0..pixels.len())
                    .map(|column| if lit(row, column) { '#' } else { '.' })
                    .collect()
            })
            .collect();
        assert_eq!(
            (
                shown(&lines),
                lines.iter().map(Line::width).collect::<Vec<_>>()
            ),
            (expected, vec![26, 26, 26])
        );
    }

    #[test]
    fn points_at_the_middle_of_the_vs_bottom() {
        // The V spans pixel columns 22 to 36, between the N and the I.
        let bottom: Vec<usize> = (22..37)
            .filter(|column| BITMAP[BITMAP.len() - 1].as_bytes()[*column] == b'#')
            .collect();
        assert_eq!(bottom[bottom.len() / 2] / 2, V_POINT);
    }

    #[test]
    fn flows_the_brand_gradient_without_a_seam() {
        assert_eq!(
            (
                flowing(0.),
                flowing(0.25),
                flowing(0.5),
                flowing(0.75),
                flowing(1.),
                flowing(-0.25)
            ),
            (
                GRADIENT[0],
                GRADIENT[1],
                GRADIENT[2],
                GRADIENT[1],
                GRADIENT[0],
                GRADIENT[1]
            )
        );
    }
}
