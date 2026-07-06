//! Resolves `${VAR}` and `${VAR:-default}` environment-variable expressions in
//! the raw config file before it is parsed as YAML. A default may nest another
//! `${...}` expression and is evaluated lazily, only when its value is used.

use anyhow::{anyhow, Result};

enum DefaultExpr<'a> {
    None,
    ForMissing(&'a str),
    ForMissingAndEmpty(&'a str),
}

/// Byte index of the `}` closing the `${` opened just before `from`,
/// accounting for nested `${...}`. None if the expression is unbalanced.
fn find_close(input: &str, from: usize) -> Option<usize> {
    let bytes = input.as_bytes();
    let mut depth = 1usize;
    let mut j = from;
    while j < bytes.len() {
        if bytes[j] == b'$' && bytes.get(j + 1) == Some(&b'{') {
            depth += 1;
            j += 2;
        } else if bytes[j] == b'}' {
            depth -= 1;
            if depth == 0 {
                return Some(j);
            }
            j += 1;
        } else {
            j += 1;
        }
    }
    None
}

/// Splits `inner` at the first top-level `-` (ignoring any `-` nested
/// inside `${...}`). A `:` immediately before it selects the `:-` form.
fn split(inner: &str) -> (&str, DefaultExpr<'_>) {
    let bytes = inner.as_bytes();
    let mut depth = 0usize;
    let mut j = 0;
    while j < bytes.len() {
        if bytes[j] == b'$' && bytes.get(j + 1) == Some(&b'{') {
            depth += 1;
            j += 2;
        } else if bytes[j] == b'}' {
            depth -= 1;
            j += 1;
        } else if bytes[j] == b'-' && depth == 0 {
            if j > 0 && bytes[j - 1] == b':' {
                return (
                    &inner[..j - 1],
                    DefaultExpr::ForMissingAndEmpty(&inner[j + 1..]),
                );
            }
            return (&inner[..j], DefaultExpr::ForMissing(&inner[j + 1..]));
        } else {
            j += 1;
        }
    }
    (inner, DefaultExpr::None)
}

struct Interpolator<F: FnMut(&str) -> Option<String>> {
    get_env: F,
    missing_vars: Vec<String>,
    invalid_vars: Vec<String>,
}

impl<F: FnMut(&str) -> Option<String>> Interpolator<F> {
    /// Walks `input`, copying text verbatim and resolving every top-level
    /// `${...}`. A `${` with no matching `}` is a hard error rather than
    /// being left in place, since it always indicates a malformed config.
    fn interpolate(&mut self, input: &str) -> Result<String> {
        let bytes = input.as_bytes();
        let mut output = String::with_capacity(input.len());
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == b'$' && bytes.get(i + 1) == Some(&b'{') {
                let inner_start = i + 2;
                let close = find_close(input, inner_start).ok_or_else(|| {
                    anyhow!(
                        "Failed to interpolate variables into your config file. Unbalanced \
                             '${{' expression: {}",
                        &input[i..]
                    )
                })?;
                let resolved = self.eval(&input[inner_start..close])?;
                output.push_str(&resolved);
                i = close + 1;
            } else {
                let ch = input[i..].chars().next().unwrap();
                output.push(ch);
                i += ch.len_utf8();
            }
        }
        Ok(output)
    }

    /// Resolves the contents of a single `${...}`. The default expression
    /// is itself interpolated, and only when its value is actually needed —
    /// so `${SET:-${UNSET}}` never evaluates UNSET.
    fn eval(&mut self, inner: &str) -> Result<String> {
        let (name, default) = split(inner);

        if name.is_empty()
            || name.chars().next().is_some_and(|c| c.is_ascii_digit())
            || !name
                .chars()
                .all(|c| matches!(c, 'a'..='z' | 'A'..='Z' | '0'..='9' | '_'))
        {
            // Wrap invalid names in quotes so spaces are visible in the error.
            self.invalid_vars.push(format!("\"{name}\""));
            return Ok(String::new());
        }

        match ((self.get_env)(name), default) {
            (Some(val), DefaultExpr::ForMissingAndEmpty(default)) if val.is_empty() => {
                self.interpolate(default)
            }
            (Some(val), _) => Ok(val),
            (None, DefaultExpr::ForMissing(default))
            | (None, DefaultExpr::ForMissingAndEmpty(default)) => self.interpolate(default),
            (None, DefaultExpr::None) => {
                self.missing_vars.push(name.to_string());
                Ok(String::new())
            }
        }
    }
}

pub fn interpolate_config_variables(
    config_string: String,
    get_env: impl FnMut(&str) -> Option<String>,
) -> Result<String> {
    let mut interpolator = Interpolator {
        get_env,
        missing_vars: Vec::new(),
        invalid_vars: Vec::new(),
    };
    let result = interpolator.interpolate(&config_string)?;

    if !interpolator.invalid_vars.is_empty() {
        return Err(anyhow!(
            "Failed to interpolate variables into your config file. Invalid environment \
                 variables are present: {}",
            interpolator.invalid_vars.join(", ")
        ));
    }

    if !interpolator.missing_vars.is_empty() {
        return Err(anyhow!(
            "Failed to interpolate variables into your config file. Environment variables are \
                 not present: {}",
            interpolator.missing_vars.join(", ")
        ));
    }

    Ok(result)
}

#[cfg(test)]
mod test {
    use pretty_assertions::assert_eq;

    #[test]
    fn test_interpolate_config_variables_with_single_capture() {
        let config_string = r#"
chains:
  - id: ${ENVIO_NETWORK_ID}
    start_block: 0
"#;
        let interpolated_config_string =
            super::interpolate_config_variables(config_string.to_string(), |name| match name {
                "ENVIO_NETWORK_ID" => Some("0".to_string()),
                _ => None,
            })
            .unwrap();
        assert_eq!(
            interpolated_config_string,
            r#"
chains:
  - id: 0
    start_block: 0
"#
        );
    }

    #[test]
    fn test_interpolate_config_variables_with_multiple_captures() {
        let config_string = r#"
chains:
  - id: ${ENVIO_NETWORK_ID}
    rpc:
      url: ${ENVIO_ETH_RPC_URL}?api_key=${ENVIO_ETH_RPC_KEY}
"#;
        let interpolated_config_string =
            super::interpolate_config_variables(config_string.to_string(), |name| match name {
                "ENVIO_NETWORK_ID" => Some("0".to_string()),
                "ENVIO_ETH_RPC_URL" => Some("https://eth.com".to_string()),
                "ENVIO_ETH_RPC_KEY" => Some("foo".to_string()),
                _ => None,
            })
            .unwrap();
        assert_eq!(
            interpolated_config_string,
            r#"
chains:
  - id: 0
    rpc:
      url: https://eth.com?api_key=foo
"#
        );
    }

    #[test]
    fn test_interpolate_config_variables_with_no_captures() {
        let config_string = r#"
chains:
  - id: 0
    start_block: 0
"#;
        let interpolated_config_string =
            super::interpolate_config_variables(config_string.to_string(), |name| match name {
                "ENVIO_NETWORK_ID" => Some("0".to_string()),
                _ => None,
            })
            .unwrap();
        assert_eq!(
            interpolated_config_string,
            r#"
chains:
  - id: 0
    start_block: 0
"#
        );
    }

    #[test]
    fn test_interpolate_config_variables_with_missing_env() {
        let config_string = r#"
chains:
  - id: ${ENVIO_NETWORK_ID}
    rpc:
      url: https://eth.com?api_key=${ENVIO_ETH_API_KEY}
"#;
        let interpolated_config_string =
            super::interpolate_config_variables(config_string.to_string(), |name| match name {
                "ENVIO_NETWORK_ID" => Some("0".to_string()),
                _ => None,
            })
            .unwrap_err();
        assert_eq!(
            interpolated_config_string.to_string(),
            r#"Failed to interpolate variables into your config file. Environment variables are not present: ENVIO_ETH_API_KEY"#
        );
    }

    #[test]
    fn test_interpolate_config_variables_with_invalid_captures_and_missing_env() {
        let config_string = r#"
chains:
  - id: ${ENVIO_NETWORK_ID}
    rpc:
      url: ${My RPC URL}?api_key=${}
"#;
        let interpolated_config_string =
            super::interpolate_config_variables(config_string.to_string(), |name| match name {
                "ENVIO_NETWORK_ID" => Some("0".to_string()),
                _ => None,
            })
            .unwrap_err();
        assert_eq!(
            interpolated_config_string.to_string(),
            r#"Failed to interpolate variables into your config file. Invalid environment variables are present: "My RPC URL", """#
        );
    }

    #[test]
    fn test_interpolate_config_variables_with_different_substituations() {
        let config_string = r#"
DirectSubstitution with existing env: "${EXISTING_ENV}"
DefaultForMissing with existing env: "${EXISTING_ENV-default}"
DefaultForMissing with existing env and many dashes: "${EXISTING_ENV----:---}"
DefaultForMissing with missing env: "${MISSING_ENV-default}"
DefaultForMissing with missing env and many dashes: "${MISSING_ENV----:---}"
DefaultForMissing with missing env and empty default: "${MISSING_ENV-}"
DefaultForMissingAndEmpty with existing env: "${EXISTING_ENV:-default}"
DefaultForMissingAndEmpty with existing env and many dashes: "${EXISTING_ENV:----:---}"
DefaultForMissingAndEmpty with missing env: "${MISSING_ENV:-default}"
DefaultForMissingAndEmpty with missing env and many dashes: "${MISSING_ENV:----:---}"
DefaultForMissingAndEmpty with missing env and empty default: "${MISSING_ENV:-}"
DefaultForMissingAndEmpty with empty env: "${EMPTY_ENV:-default}"
DefaultForMissingAndEmpty with empty env and many dashes: "${EMPTY_ENV:----:---}"
DefaultForMissingAndEmpty with empty env and empty default: "${EMPTY_ENV:-}"
"#;
        let interpolated_config_string =
            super::interpolate_config_variables(config_string.to_string(), |name| match name {
                "EXISTING_ENV" => Some("val".to_string()),
                "EMPTY_ENV" => Some("".to_string()),
                _ => None,
            })
            .unwrap();
        assert_eq!(
            interpolated_config_string,
            r#"
DirectSubstitution with existing env: "val"
DefaultForMissing with existing env: "val"
DefaultForMissing with existing env and many dashes: "val"
DefaultForMissing with missing env: "default"
DefaultForMissing with missing env and many dashes: "---:---"
DefaultForMissing with missing env and empty default: ""
DefaultForMissingAndEmpty with existing env: "val"
DefaultForMissingAndEmpty with existing env and many dashes: "val"
DefaultForMissingAndEmpty with missing env: "default"
DefaultForMissingAndEmpty with missing env and many dashes: "---:---"
DefaultForMissingAndEmpty with missing env and empty default: ""
DefaultForMissingAndEmpty with empty env: "default"
DefaultForMissingAndEmpty with empty env and many dashes: "---:---"
DefaultForMissingAndEmpty with empty env and empty default: ""
"#
        );
    }

    #[test]
    fn test_interpolate_nested_default_expressions() {
        let config_string = r#"
outer present, inner missing: "${EXISTING_ENV:-${MISSING_ENV}}"
outer missing, inner present: "${MISSING_ENV:-${EXISTING_ENV}}"
hyphen form, outer missing: "${MISSING_ENV-${EXISTING_ENV}}"
two levels, all missing: "${MISSING_ENV:-${OTHER_MISSING:-fallback}}"
empty outer, inner present: "${EMPTY_ENV:-${EXISTING_ENV}}"
trailing brace after expr: "${MISSING_ENV:-x}}"
"#;
        let interpolated_config_string =
            super::interpolate_config_variables(config_string.to_string(), |name| match name {
                "EXISTING_ENV" => Some("val".to_string()),
                "EMPTY_ENV" => Some("".to_string()),
                _ => None,
            })
            .unwrap();
        assert_eq!(
            interpolated_config_string,
            r#"
outer present, inner missing: "val"
outer missing, inner present: "val"
hyphen form, outer missing: "val"
two levels, all missing: "fallback"
empty outer, inner present: "val"
trailing brace after expr: "x}"
"#
        );
    }

    #[test]
    fn test_interpolate_nested_reports_only_evaluated_missing_var() {
        let config_string = r#"url: ${MISSING_OUTER:-${MISSING_INNER}}"#;
        let err =
            super::interpolate_config_variables(config_string.to_string(), |_| None).unwrap_err();
        assert_eq!(
                err.to_string(),
                "Failed to interpolate variables into your config file. Environment variables are not present: MISSING_INNER"
            );
    }

    #[test]
    fn test_interpolate_unbalanced_expression_is_hard_error() {
        let config_string = r#"url: ${MISSING:-${FALLBACK}"#;
        let err =
            super::interpolate_config_variables(config_string.to_string(), |_| None).unwrap_err();
        assert_eq!(
                err.to_string(),
                "Failed to interpolate variables into your config file. Unbalanced '${' expression: ${MISSING:-${FALLBACK}"
            );
    }
}
