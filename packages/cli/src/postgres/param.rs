//! Bound query parameters.
//!
//! Every parameter goes to the server in its text representation, which is what
//! the driver this replaces sent and therefore what the stored values were
//! produced from. Binary format would be faster to encode but not identical:
//! `numeric`, `timestamptz` and the float types each round-trip differently
//! through it, and the statements here were written against text.
//!
//! The server tells the driver what type each parameter is — the statement's own
//! casts decide it — so a parameter never has to name its type, only render
//! itself.

use bytes::BytesMut;
use tokio_postgres::types::{to_sql_checked, Format, IsNull, ToSql, Type};

/// A bound value, already rendered.
///
/// `Null` is distinct from an empty `Text`: an empty string is a value, and a
/// column that holds one must not read back as NULL.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Param {
    Null,
    Text(String),
}

impl ToSql for Param {
    fn to_sql(
        &self,
        _ty: &Type,
        out: &mut BytesMut,
    ) -> Result<IsNull, Box<dyn std::error::Error + Sync + Send>> {
        match self {
            Param::Null => Ok(IsNull::Yes),
            Param::Text(text) => {
                out.extend_from_slice(text.as_bytes());
                Ok(IsNull::No)
            }
        }
    }

    /// Whatever the statement says the parameter is. Refusing a type here would
    /// only move a server-side error earlier while knowing less than the server
    /// does about what the cast accepts.
    fn accepts(_ty: &Type) -> bool {
        true
    }

    fn encode_format(&self, _ty: &Type) -> Format {
        Format::Text
    }

    to_sql_checked!();
}

/// Renders a Postgres array literal — `{a,b,NULL}` — from already-rendered
/// elements.
///
/// An element is quoted and escaped unless it is NULL, which has to stay bare:
/// quoted, it would be the four-character string instead of the absence of a
/// value. Quoting everything else spares this from having to know which
/// characters the element type treats as special — a comma inside a text
/// element, a brace inside JSON — since inside quotes only the quote and the
/// backslash still mean anything.
pub fn array_literal<'a>(elements: impl IntoIterator<Item = Option<&'a str>>) -> String {
    let mut rendered = String::from("{");
    for (index, element) in elements.into_iter().enumerate() {
        if index > 0 {
            rendered.push(',');
        }
        match element {
            None => rendered.push_str("NULL"),
            Some(element) => {
                rendered.push('"');
                for byte in element.chars() {
                    if byte == '"' || byte == '\\' {
                        rendered.push('\\');
                    }
                    rendered.push(byte);
                }
                rendered.push('"');
            }
        }
    }
    rendered.push('}');
    rendered
}

/// The `\x`-prefixed hex Postgres reads as a `bytea` literal.
pub fn bytea_literal(bytes: &[u8]) -> String {
    let mut rendered = String::with_capacity(2 + bytes.len() * 2);
    rendered.push_str("\\x");
    for byte in bytes {
        rendered.push_str(&format!("{byte:02x}"));
    }
    rendered
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_array_quotes_its_elements_and_leaves_null_bare() {
        assert_eq!(
            array_literal([Some("a"), None, Some("b")]),
            "{\"a\",NULL,\"b\"}"
        );
    }

    /// Unquoted, each of these would end the element early or be read as
    /// something other than itself.
    #[test]
    fn an_element_survives_the_characters_an_array_reads() {
        assert_eq!(
            array_literal([
                Some("a,b"),
                Some("{nested}"),
                Some("has \"quotes\""),
                Some("back\\slash"),
                Some(""),
                Some("NULL"),
            ]),
            "{\"a,b\",\"{nested}\",\"has \\\"quotes\\\"\",\"back\\\\slash\",\"\",\"NULL\"}"
        );
    }

    /// The string `NULL` is a value; the absence of one is not. Quoting keeps
    /// them apart.
    #[test]
    fn the_word_null_is_not_the_absence_of_a_value() {
        assert_ne!(array_literal([Some("NULL")]), array_literal([None]));
    }

    #[test]
    fn an_empty_array_is_a_pair_of_braces() {
        assert_eq!(array_literal([]), "{}");
    }

    #[test]
    fn bytes_render_as_hex() {
        assert_eq!(
            (
                bytea_literal(&[0xde, 0xad, 0xbe, 0xef]),
                bytea_literal(&[0x00, 0x0f]),
                bytea_literal(&[]),
            ),
            (
                "\\xdeadbeef".to_string(),
                "\\x000f".to_string(),
                "\\x".to_string(),
            )
        );
    }

    #[test]
    fn an_empty_string_is_not_null() {
        assert_ne!(Param::Text(String::new()), Param::Null);
    }
}
