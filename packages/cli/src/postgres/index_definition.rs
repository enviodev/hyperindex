//! What the indexer wants an index to be, and the DDL for it.
//!
//! A table, its ordered key columns with their directions, and an access
//! method. That tuple is the index's identity; the name is derived from it
//! rather than being part of it, so the catalog can always be matched on what
//! an index actually covers.

pub const BTREE: &str = "btree";

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Direction {
    Asc,
    Desc,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct IndexColumn {
    pub name: String,
    pub direction: Direction,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct IndexDefinition {
    pub table_name: String,
    pub columns: Vec<IndexColumn>,
    pub method: String,
}

/// 2166136261, the FNV offset basis, as a signed 32-bit integer.
const FNV_OFFSET_BASIS: i32 = -2128831035;
const FNV_PRIME: i32 = 16777619;
const HASH_LENGTH: usize = 10;
const PG_MAX_IDENTIFIER_LENGTH: usize = 63;
const MAX_PREFIX_LENGTH: usize = PG_MAX_IDENTIFIER_LENGTH - HASH_LENGTH - 1;

/// Hashes the UTF-16 code units of `input`, which is what the JavaScript this
/// was ported from iterated and so what the stored index names were built from.
/// Every key is ASCII in practice — table and column names come from GraphQL —
/// but the encoding is part of the identity either way.
fn fnv1a(input: &str, seed: i32) -> i32 {
    let mut hash = seed;
    for unit in input.encode_utf16() {
        hash = (hash ^ i32::from(unit)).wrapping_mul(FNV_PRIME);
    }
    hash
}

fn to_base36(value: u32, length: usize) -> String {
    let mut digits = Vec::new();
    let mut value = value;
    if value == 0 {
        digits.push(b'0');
    }
    while value > 0 {
        let digit = (value % 36) as u8;
        digits.push(if digit < 10 {
            b'0' + digit
        } else {
            b'a' + digit - 10
        });
        value /= 36;
    }
    digits.reverse();
    let rendered = String::from_utf8(digits).expect("base36 digits are ASCII");
    if rendered.len() >= length {
        rendered
    } else {
        format!("{}{rendered}", "0".repeat(length - rendered.len()))
    }
}

impl IndexDefinition {
    pub fn column_key(column: &IndexColumn) -> String {
        match column.direction {
            Direction::Asc => column.name.clone(),
            Direction::Desc => format!("{} DESC", column.name),
        }
    }

    /// The index's identity. Two definitions covering the same thing share it,
    /// which is how a list of them is deduped.
    pub fn key(&self) -> String {
        format!(
            "{}|{}|{}",
            self.table_name,
            self.method,
            self.columns
                .iter()
                .map(Self::column_key)
                .collect::<Vec<_>>()
                .join(",")
        )
    }

    /// 50 bits of the identity, base36-encoded. Two indexes sharing a hash would
    /// share an identifier, so the width matters: 50 bits is far past the number
    /// of indexes a schema can hold, while still fitting in 10 characters. The
    /// halves are hashed separately because combining them would overflow the
    /// 32-bit arithmetic.
    fn identity_hash(&self) -> String {
        let key = self.key();
        let low = (fnv1a(&key, FNV_OFFSET_BASIS) as u32) >> 2;
        let high = (fnv1a(&key, FNV_OFFSET_BASIS ^ 0x27d4eb2f) as u32) >> 12;
        format!("{}{}", to_base36(low, 6), to_base36(high, 4))
    }

    /// `<Entity>_<column>`, with each further column appended in order. Only
    /// there so a human reading `\d` output can tell what the index is for.
    pub fn readable_prefix(&self) -> String {
        let mut prefix = self.table_name.clone();
        for column in &self.columns {
            prefix.push('_');
            prefix.push_str(&column.name);
            if column.direction == Direction::Desc {
                prefix.push_str("_desc");
            }
        }
        prefix
    }

    /// Postgres truncates identifiers past 63 bytes on its own, and two long
    /// field names would then collapse onto one name. Truncating only the
    /// readable half and keeping the hash whole makes every generated name
    /// distinct by construction. Prefixes are ASCII — GraphQL names are — so
    /// characters and Postgres' byte limit line up.
    pub fn name(&self) -> String {
        let prefix = self.readable_prefix();
        let prefix = if prefix.chars().count() > MAX_PREFIX_LENGTH {
            prefix.chars().take(MAX_PREFIX_LENGTH).collect()
        } else {
            prefix
        };
        format!("{prefix}_{}", self.identity_hash())
    }

    fn columns_sql(&self) -> String {
        self.columns
            .iter()
            .map(|column| match column.direction {
                Direction::Asc => format!("\"{}\"", column.name),
                Direction::Desc => format!("\"{}\" DESC", column.name),
            })
            .collect::<Vec<_>>()
            .join(", ")
    }

    /// Plain DDL, not CONCURRENTLY: it builds from a single table scan instead
    /// of two, and the SHARE lock it takes blocks writes but not reads, so
    /// queries keep being served while it runs. The indexer is the only writer,
    /// and every caller is happy to wait on it.
    ///
    /// No `IF NOT EXISTS` either — a skipped create is indistinguishable from a
    /// successful one, and the whole point of the generated name is that nothing
    /// else can hold it.
    pub fn create_query(&self, pg_schema: &str) -> String {
        let using = if self.method == BTREE {
            String::new()
        } else {
            format!(" USING {}", self.method)
        };
        format!(
            "CREATE INDEX \"{}\" ON \"{pg_schema}\".\"{}\"{using}({});",
            self.name(),
            self.table_name,
            self.columns_sql()
        )
    }
}

pub fn drop_query(pg_schema: &str, index_name: &str) -> String {
    format!("DROP INDEX IF EXISTS \"{pg_schema}\".\"{index_name}\";")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn asc(name: &str) -> IndexColumn {
        IndexColumn {
            name: name.to_string(),
            direction: Direction::Asc,
        }
    }

    fn desc(name: &str) -> IndexColumn {
        IndexColumn {
            name: name.to_string(),
            direction: Direction::Desc,
        }
    }

    fn definition(table_name: &str, columns: Vec<IndexColumn>, method: &str) -> IndexDefinition {
        IndexDefinition {
            table_name: table_name.to_string(),
            columns,
            method: method.to_string(),
        }
    }

    /// Every expectation here was produced by the ReScript this replaces, so an
    /// index keeps the name it already has in every deployed schema. A drifting
    /// hash would silently build a second copy of an index that is already
    /// there.
    #[test]
    fn names_match_the_implementation_this_replaces() {
        let cases = [
            (
                definition("A", vec![asc("b_id")], BTREE),
                "A|btree|b_id",
                "A_b_id_556h9mdu8a",
                "CREATE INDEX \"A_b_id_556h9mdu8a\" ON \"test_schema\".\"A\"(\"b_id\");",
            ),
            (
                definition("A", vec![desc("b_id")], BTREE),
                "A|btree|b_id DESC",
                "A_b_id_desc_f17av6bu2y",
                "CREATE INDEX \"A_b_id_desc_f17av6bu2y\" ON \"test_schema\".\"A\"(\"b_id\" DESC);",
            ),
            (
                definition("Token", vec![asc("owner"), desc("created_at")], BTREE),
                "Token|btree|owner,created_at DESC",
                "Token_owner_created_at_desc_2baizzlj79",
                "CREATE INDEX \"Token_owner_created_at_desc_2baizzlj79\" ON \"test_schema\".\"Token\"(\"owner\", \"created_at\" DESC);",
            ),
            (
                definition("Token", vec![asc("owner")], "gin"),
                "Token|gin|owner",
                "Token_owner_4efnblhbrx",
                "CREATE INDEX \"Token_owner_4efnblhbrx\" ON \"test_schema\".\"Token\" USING gin(\"owner\");",
            ),
            (
                definition(
                    "EntityWith63LenghtName______________________________________one",
                    vec![asc("some_quite_long_column_name_here")],
                    BTREE,
                ),
                "EntityWith63LenghtName______________________________________one|btree|some_quite_long_column_name_here",
                "EntityWith63LenghtName_______________________________14qj9chwtd",
                "CREATE INDEX \"EntityWith63LenghtName_______________________________14qj9chwtd\" ON \"test_schema\".\"EntityWith63LenghtName______________________________________one\"(\"some_quite_long_column_name_here\");",
            ),
            (
                definition("e", vec![asc("x")], BTREE),
                "e|btree|x",
                "e_x_drfgb2iklc",
                "CREATE INDEX \"e_x_drfgb2iklc\" ON \"test_schema\".\"e\"(\"x\");",
            ),
            (
                definition("Multi", vec![asc("a"), asc("b"), desc("c")], BTREE),
                "Multi|btree|a,b,c DESC",
                "Multi_a_b_c_desc_er4sbpbz9k",
                "CREATE INDEX \"Multi_a_b_c_desc_er4sbpbz9k\" ON \"test_schema\".\"Multi\"(\"a\", \"b\", \"c\" DESC);",
            ),
        ];

        let actual = cases
            .iter()
            .map(|(definition, ..)| {
                (
                    definition.key(),
                    definition.name(),
                    definition.create_query("test_schema"),
                )
            })
            .collect::<Vec<_>>();
        let expected = cases
            .iter()
            .map(|(_, key, name, create)| (key.to_string(), name.to_string(), create.to_string()))
            .collect::<Vec<_>>();
        assert_eq!(actual, expected);
    }

    #[test]
    fn a_generated_name_always_fits_postgres() {
        let long = definition(
            "EntityWith63LenghtName______________________________________one",
            vec![asc("some_quite_long_column_name_here")],
            BTREE,
        );
        assert_eq!(long.name().len(), PG_MAX_IDENTIFIER_LENGTH);
    }

    #[test]
    fn the_hash_is_always_its_full_width() {
        // Nothing may shorten it: the truncated prefix is what keeps a name
        // under the limit, and a short hash would let two collide.
        let widths = (0..500)
            .map(|index| {
                definition("T", vec![asc(&format!("column_{index}"))], BTREE)
                    .identity_hash()
                    .len()
            })
            .collect::<std::collections::HashSet<_>>();
        assert_eq!(widths, std::collections::HashSet::from([HASH_LENGTH]));
    }

    #[test]
    fn definitions_that_cover_the_same_thing_share_a_key() {
        assert_eq!(
            (
                definition("A", vec![asc("b")], BTREE).key()
                    == definition("A", vec![desc("b")], BTREE).key(),
                definition("A", vec![asc("b")], BTREE).key()
                    == definition("A", vec![asc("b")], "gin").key(),
            ),
            (false, false)
        );
    }

    #[test]
    fn dropping_an_index_names_it_in_its_schema() {
        assert_eq!(
            drop_query("test_schema", "A_b_id_556h9mdu8a"),
            "DROP INDEX IF EXISTS \"test_schema\".\"A_b_id_556h9mdu8a\";"
        );
    }
}
