pub fn number(value: f64) -> String {
    let rounded = value.round() as i64;
    let digits = rounded.unsigned_abs().to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3 + 1);
    if rounded < 0 {
        out.push('-');
    }
    for (i, digit) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

/// Below ten thousand in full, so a small count never reads as a rounded one.
pub fn compact(value: f64) -> String {
    if value.abs() < 10_000. {
        return number(value);
    }
    let mut scaled = value / 1000.;
    for unit in ["K", "M", "B"] {
        // Rounds the way it prints, so 999,960 is 1.0M rather than 1000.0K.
        if (scaled * 10.).round().abs() < 10_000. || unit == "B" {
            return format!("{scaled:.1}{unit}");
        }
        scaled /= 1000.;
    }
    unreachable!()
}

/// The two largest units, the second padded so a ticking value keeps its
/// width. Hours stay unbounded rather than rolling over into days, so a
/// multi-day ETA reads as "50h 03m" instead of silently dropping the days.
pub fn duration(ms: f64) -> String {
    let seconds = (ms / 1000.).floor().max(0.) as i64;
    let (hours, minutes, seconds) = (seconds / 3600, seconds % 3600 / 60, seconds % 60);
    if hours > 0 {
        format!("{hours}h {minutes:02}m")
    } else if minutes > 0 {
        format!("{minutes}m {seconds:02}s")
    } else {
        format!("{seconds}s")
    }
}

pub fn home_relative(path: &str, home: &str) -> String {
    let home = home.trim_end_matches('/');
    match path.strip_prefix(home) {
        Some(rest) if !home.is_empty() && (rest.is_empty() || rest.starts_with('/')) => {
            format!("~{rest}")
        }
        _ => path.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shortens_paths_under_home_to_a_tilde() {
        assert_eq!(
            [
                home_relative("/home/dev/code/indexer", "/home/dev"),
                home_relative("/home/dev", "/home/dev/"),
                home_relative("/home/developer/indexer", "/home/dev"),
                home_relative("/srv/indexer", "/"),
            ],
            [
                "~/code/indexer",
                "~",
                "/home/developer/indexer",
                "/srv/indexer"
            ]
        );
    }

    #[test]
    fn formats_numbers_with_thousands_separators() {
        let formatted: Vec<String> = [0., 1., 999., 1000., 1234567., 1234.6, -1234.]
            .into_iter()
            .map(number)
            .collect();
        assert_eq!(
            formatted,
            vec!["0", "1", "999", "1,000", "1,234,567", "1,235", "-1,234"]
        );
    }

    #[test]
    fn formats_large_numbers_compactly() {
        let formatted: Vec<String> = [
            9_999.,
            10_000.,
            903_412.,
            999_960.,
            21_000_000.,
            301_229_870.,
            4_200_000_000_000.,
        ]
        .into_iter()
        .map(compact)
        .collect();
        assert_eq!(
            formatted,
            vec!["9,999", "10.0K", "903.4K", "1.0M", "21.0M", "301.2M", "4200.0B"]
        );
    }

    #[test]
    fn formats_durations_in_their_two_largest_units() {
        let formatted: Vec<String> = [0., 999., 1000., 61_000., 242_000., 3_600_000., 180_301_000.]
            .into_iter()
            .map(duration)
            .collect();
        assert_eq!(
            formatted,
            vec!["0s", "0s", "1s", "1m 01s", "4m 02s", "1h 00m", "50h 05m"]
        );
    }
}
