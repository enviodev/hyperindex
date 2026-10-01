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

fn plural(count: i64, unit: &str) -> String {
    if count == 1 {
        format!("1 {unit}")
    } else {
        format!("{count} {unit}s")
    }
}

/// Hours stay unbounded rather than rolling over into days, so a multi-day
/// ETA reads as "50 hours" instead of silently dropping the days.
pub fn duration(ms: f64) -> String {
    let total_seconds = (ms / 1000.).floor().max(0.) as i64;
    let parts: Vec<String> = [
        (total_seconds / 3600, "hour"),
        (total_seconds % 3600 / 60, "minute"),
        (total_seconds % 60, "second"),
    ]
    .into_iter()
    .filter(|(count, _)| *count > 0)
    .map(|(count, unit)| plural(count, unit))
    .collect();
    if parts.is_empty() {
        "less than 1 second".to_string()
    } else {
        parts.join(" ")
    }
}

const MINUTES_IN_DAY: i64 = 1440;
const MINUTES_IN_MONTH: i64 = 43200;

/// The wording of date-fns `formatDistance` with `includeSeconds`, with months
/// approximated as 30 days.
pub fn distance(from_ms: f64, to_ms: f64) -> String {
    let seconds = ((to_ms - from_ms).abs() / 1000.).trunc() as i64;
    let minutes = (seconds as f64 / 60.).round() as i64;
    if minutes < 2 {
        return match seconds {
            0..=4 => "less than 5 seconds".to_string(),
            5..=9 => "less than 10 seconds".to_string(),
            10..=19 => "less than 20 seconds".to_string(),
            20..=39 => "half a minute".to_string(),
            40..=59 => "less than a minute".to_string(),
            _ => "1 minute".to_string(),
        };
    }
    if minutes < 45 {
        return plural(minutes, "minute");
    }
    if minutes < 90 {
        return "about 1 hour".to_string();
    }
    if minutes < MINUTES_IN_DAY {
        let hours = (minutes as f64 / 60.).round() as i64;
        return format!("about {}", plural(hours, "hour"));
    }
    if minutes < 2520 {
        return "1 day".to_string();
    }
    if minutes < MINUTES_IN_MONTH {
        return plural(
            (minutes as f64 / MINUTES_IN_DAY as f64).round() as i64,
            "day",
        );
    }
    if minutes < MINUTES_IN_MONTH * 2 {
        return "about 1 month".to_string();
    }
    let months = minutes / MINUTES_IN_MONTH;
    if months < 12 {
        return plural(
            (minutes as f64 / MINUTES_IN_MONTH as f64).round() as i64,
            "month",
        );
    }
    let years = months / 12;
    match months % 12 {
        0..=2 => format!("about {}", plural(years, "year")),
        3..=8 => format!("over {}", plural(years, "year")),
        _ => format!("almost {}", plural(years + 1, "year")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn formats_durations_without_rolling_hours_into_days() {
        let formatted: Vec<String> = [
            0.,
            500.,
            1000.,
            61_000.,
            3_600_000.,
            7_322_000.,
            90_061_000.,
        ]
        .into_iter()
        .map(duration)
        .collect();
        assert_eq!(
            formatted,
            vec![
                "less than 1 second",
                "less than 1 second",
                "1 second",
                "1 minute 1 second",
                "1 hour",
                "2 hours 2 minutes 2 seconds",
                "25 hours 1 minute 1 second",
            ]
        );
    }

    // Expected strings come from date-fns 3.3.1 `formatDistance` with
    // `includeSeconds: true`.
    #[test]
    fn formats_distances_like_date_fns() {
        let seconds = [
            0, 4, 5, 9, 10, 19, 20, 39, 40, 59, 60, 89, 90, 119, 150, 2699, 5399, 9000, 86399,
            151199, 151200, 2591999, 5184000, 30000000, 40000000,
        ];
        let formatted: Vec<String> = seconds
            .into_iter()
            .map(|s| distance(0., s as f64 * 1000.))
            .collect();
        assert_eq!(
            formatted,
            vec![
                "less than 5 seconds",
                "less than 5 seconds",
                "less than 10 seconds",
                "less than 10 seconds",
                "less than 20 seconds",
                "less than 20 seconds",
                "half a minute",
                "half a minute",
                "less than a minute",
                "less than a minute",
                "1 minute",
                "1 minute",
                "2 minutes",
                "2 minutes",
                "3 minutes",
                "about 1 hour",
                "about 2 hours",
                "about 3 hours",
                "1 day",
                "2 days",
                "2 days",
                "about 1 month",
                "2 months",
                "12 months",
                "over 1 year",
            ]
        );
    }
}
