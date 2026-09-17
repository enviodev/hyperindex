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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_string_is_not_null() {
        assert_ne!(Param::Text(String::new()), Param::Null);
    }
}
