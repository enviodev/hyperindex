use ratatui::{
    style::{Color, Style},
    text::{Line, Span},
};

// The brand wordmark, two pixels per terminal row so the strokes keep the
// logo's proportions.
const LETTERS: [&[&str; 8]; 5] = [
    &[
        "#######", "#######", "##.....", "######.", "######.", "##.....", "#######", "#######",
    ],
    &[
        "####..##", "####..##", "##.##.##", "##.##.##", "##..####", "##..####", "##...###",
        "##...###",
    ],
    &[
        "##......##",
        "##......##",
        ".##....##.",
        ".##....##.",
        "..##..##..",
        "..##..##..",
        "...####...",
        "....##....",
    ],
    &["##", "##", "##", "##", "##", "##", "##", "##"],
    &[
        ".#######.",
        "#########",
        "##.....##",
        "##.....##",
        "##.....##",
        "##.....##",
        "#########",
        ".#######.",
    ],
];

const GAP: usize = 2;
const GRADIENT: [(u8, u8, u8); 3] = [(0xFF, 0x82, 0x67), (0xFF, 0xA1, 0x52), (0xFD, 0xD7, 0x00)];

fn pixels() -> [Vec<bool>; 8] {
    std::array::from_fn(|row| {
        let mut pixels = Vec::new();
        for (i, letter) in LETTERS.iter().enumerate() {
            if i > 0 {
                pixels.extend([false; GAP]);
            }
            pixels.extend(letter[row].chars().map(|c| c == '#'));
        }
        pixels
    })
}

pub fn width() -> usize {
    pixels()[0].len()
}

fn gradient(position: f64) -> (u8, u8, u8) {
    let scaled = position.clamp(0., 1.) * (GRADIENT.len() - 1) as f64;
    let index = (scaled.floor() as usize).min(GRADIENT.len() - 2);
    let t = scaled - index as f64;
    let (from, to) = (GRADIENT[index], GRADIENT[index + 1]);
    let mix = |a: u8, b: u8| (a as f64 + (b as f64 - a as f64) * t).round() as u8;
    (mix(from.0, to.0), mix(from.1, to.1), mix(from.2, to.2))
}

pub fn lines(rgb: impl Fn((u8, u8, u8)) -> Color) -> Vec<Line<'static>> {
    let pixels = pixels();
    let width = pixels[0].len();
    pixels
        .chunks(2)
        .map(|pair| {
            Line::from(
                (0..width)
                    .map(|x| {
                        let glyph = match (pair[0][x], pair[1][x]) {
                            (true, true) => "█",
                            (true, false) => "▀",
                            (false, true) => "▄",
                            (false, false) => " ",
                        };
                        let color = rgb(gradient(x as f64 / (width - 1) as f64));
                        Span::styled(glyph, Style::new().fg(color))
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

    #[test]
    fn draws_the_wordmark_with_half_blocks() {
        let text: Vec<String> = lines(|(r, g, b)| Color::Rgb(r, g, b))
            .iter()
            .map(|line| line.to_string())
            .collect();
        assert_eq!(
            text,
            vec![
                "███████  ████  ██  ██      ██  ██  ▄███████▄",
                "██▄▄▄▄   ██ ██ ██   ██    ██   ██  ██     ██",
                "██▀▀▀▀   ██  ████    ██  ██    ██  ██     ██",
                "███████  ██   ███     ▀██▀     ██  ▀███████▀",
            ]
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
