//! Bound query parameters.
//!
//! Every parameter goes to the server in its text representation, which is what
//! the stored values were produced from. Binary format would be faster to
//! encode but not identical: `numeric`, `timestamptz` and the float types each
//! round-trip differently through it, and the statements here were written
//! against text.
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
            // Postgres takes a NUL byte in no text-format value. One arrives
            // whenever a contract's bytes are read as text, and leaving it out
            // is what lets the rest of the value be stored.
            Param::Text(text) => {
                for part in text.as_bytes().split(|&byte| byte == 0) {
                    out.extend_from_slice(part);
                }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_string_is_not_null() {
        assert_ne!(Param::Text(String::new()), Param::Null);
    }

    #[test]
    fn a_nul_byte_is_left_out() {
        let mut out = BytesMut::new();
        Param::Text("a\0b\0".to_string())
            .to_sql(&Type::TEXT, &mut out)
            .unwrap();
        assert_eq!(&out[..], b"ab");
    }
}
