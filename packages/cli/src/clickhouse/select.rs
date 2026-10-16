//! An entity is read off its history table rather than through its view. The
//! view resolves every entity in the table before any filter applies, since
//! ClickHouse pushes nothing through `LIMIT 1 BY`; a load names the ids it
//! wants up front, so the primary key narrows the scan to them.

use std::collections::BTreeMap;

use anyhow::{bail, Context, Result};

use super::ch_type::ChType;
use super::table::{Column, Table};
use super::{literal, quoted, table_ref};
use crate::entity_filter::{Condition, Operator, ValueKind};
use crate::storage::types::{Bounds, Sequence, CHANGE_COLUMN, CHECKPOINT_ID_COLUMN, SET};

/// Where each chain's committed rows end. A row stamped past its chain's id
/// belongs to a write that has not committed.
pub type Frontier = BTreeMap<i64, i64>;

/// A read, and the lists it sends beside its text. A batch loads thousands of
/// ids at once, more than the server's cap on a statement's length holds as
/// literals, so a list of text goes as external data instead: rows the server
/// reads rather than parses.
#[derive(Debug, PartialEq)]
pub struct Read {
    pub sql: String,
    pub external: Vec<External>,
}

/// A one-column table the server reads beside a statement, its rows in
/// RowBinary.
#[derive(Debug, PartialEq)]
pub struct External {
    pub name: String,
    pub rows: Vec<u8>,
}

pub const EXTERNAL_STRUCTURE: &str = "value String";

/// The committed id a row compares against: its own chain's for a table with a
/// chain column, the whole run's otherwise. A chain the frontier doesn't name
/// has committed nothing.
fn frontier_of(chain_column: Option<&str>, frontier: &Frontier) -> String {
    match chain_column {
        // A cross-chain entity's rows only exist under one shared sequence, so
        // the highest id any chain committed is how far they are readable.
        None => frontier.values().max().copied().unwrap_or(0).to_string(),
        Some(_) if frontier.is_empty() => "0".to_string(),
        Some(column) => {
            let column = quoted(column);
            let branches = frontier
                .iter()
                .map(|(chain_id, checkpoint_id)| format!("{column} = {chain_id}, {checkpoint_id}"))
                .collect::<Vec<_>>()
                .join(", ");
            format!("multiIf({branches}, 0)")
        }
    }
}

/// The rows a bound puts above it: past the one id every chain is held to
/// under a shared sequence, past each chain's own otherwise.
pub fn above(
    bounds: &Bounds,
    chain_column: Option<&str>,
    checkpoint_column: &str,
) -> Result<String> {
    let checkpoint = quoted(checkpoint_column);
    match bounds.sequence {
        Sequence::SharedAcrossChains => Ok(format!("{checkpoint} > {}", bounds.shared_id())),
        Sequence::PerChain => {
            let Some(chain_column) = chain_column else {
                bail!(
                    "Internal error: per-chain checkpoint bounds can't bound a table with no \
                     chain-id column. Only a schema whose entities are all per-chain has them."
                )
            };
            if bounds.chain_ids.is_empty() {
                return Ok("false".to_string());
            }
            let chain = quoted(chain_column);
            Ok(format!(
                "({})",
                bounds
                    .by_chain()
                    .map(|(chain_id, checkpoint_id)| {
                        format!("({chain} = {chain_id} AND {checkpoint} > {checkpoint_id})")
                    })
                    .collect::<Vec<_>>()
                    .join(" OR ")
            ))
        }
    }
}

fn is_number(text: &str) -> bool {
    let unsigned = text.strip_prefix('-').unwrap_or(text);
    let (mantissa, exponent) = match unsigned.split_once(['e', 'E']) {
        Some((mantissa, exponent)) => (mantissa, Some(exponent)),
        None => (unsigned, None),
    };
    let (whole, fraction) = match mantissa.split_once('.') {
        Some((whole, fraction)) => (whole, Some(fraction)),
        None => (mantissa, None),
    };
    let digits = |part: &str| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit());
    digits(whole)
        && fraction.is_none_or(digits)
        && exponent
            .is_none_or(|exponent| digits(exponent.strip_prefix(['+', '-']).unwrap_or(exponent)))
}

fn number(text: &str) -> Result<&str> {
    if is_number(text) {
        Ok(text)
    } else {
        bail!("`{text}` is not a number to filter by")
    }
}

/// A Decimal wide enough to compare any value a numeric field holds, for a
/// column that keeps its numbers as text.
const TEXT_NUMBER_SCALE: u32 = 30;

/// The widest scale a Decimal256 holds.
const MAX_DECIMAL_SCALE: u32 = 76;

/// An integer as the canonical text a BigInt is kept as, which is what lets
/// two of them be compared by their text.
fn integer(text: &str) -> Result<String> {
    let (negative, digits) = match text.strip_prefix('-') {
        Some(digits) => (true, digits),
        None => (false, text),
    };
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        bail!("`{text}` is not an integer to filter by");
    }
    Ok(match digits.trim_start_matches('0') {
        "" => "0".to_string(),
        digits if negative => format!("-{digits}"),
        digits => digits.to_string(),
    })
}

/// An integer kept as text, as text that sorts the way the number does: its
/// sign, then how many digits it has, then the digits — below zero the count
/// and digits complemented, where more is less. ClickHouse's own integers stop
/// at 2^255 and wrap past it rather than refuse, and a uint256 reaches 2^256.
fn integer_order(text: &str) -> String {
    format!(
        "if(startsWith({text}, '-'), concat('0', leftPad(toString(100000 - length({text})), 5, \
         '0'), translate(substring({text}, 2), '0123456789', '9876543210')), concat('1', \
         leftPad(toString(length({text})), 5, '0'), {text}))"
    )
}

/// [`integer_order`] of a canonical integer, worked out here.
fn integer_key(canonical: &str) -> String {
    match canonical.strip_prefix('-') {
        Some(digits) => format!(
            "0{:05}{}",
            99_999 - digits.len(),
            digits
                .bytes()
                .map(|digit| char::from(b'9' - digit + b'0'))
                .collect::<String>()
        ),
        None => format!("1{:05}{canonical}", canonical.len()),
    }
}

/// The scale a value is compared at against a Decimal column of `column_scale`:
/// wide enough to keep every fractional digit the value spells, so it isn't
/// compared as a rounded neighbour, as far as a Decimal256 has room beside its
/// whole part. A value cut there is past what any such column holds anyway.
fn decimal_scale(text: &str, column_scale: u32) -> u32 {
    let (mantissa, exponent) = match text.split_once(['e', 'E']) {
        Some((mantissa, exponent)) => (mantissa, exponent.parse::<i64>().unwrap_or(0)),
        None => (text, 0),
    };
    let (whole, fraction) = mantissa
        .trim_start_matches(['-', '+'])
        .split_once('.')
        .unwrap_or((mantissa.trim_start_matches(['-', '+']), ""));
    let whole_digits = (whole.trim_start_matches('0').len() as i64 + exponent).max(0);
    let fraction_digits = (fraction.len() as i64 - exponent).max(0);
    let room = (i64::from(MAX_DECIMAL_SCALE) - whole_digits).max(0);
    i64::from(column_scale).max(fraction_digits).min(room) as u32
}

/// One element as the column's own type reads it.
fn element(text: &str, kind: ValueKind, field_type: &str, ch_type: &ChType) -> Result<String> {
    Ok(match kind {
        ValueKind::Text | ValueKind::Enum | ValueKind::Json => literal(text),
        ValueKind::Boolean => match text {
            "true" | "false" => text.to_string(),
            other => bail!("`{other}` is not a boolean to filter by"),
        },
        ValueKind::Timestamp => format!("parseDateTime64BestEffort({}, 3, 'UTC')", literal(text)),
        ValueKind::Bytes => {
            let hex = text
                .strip_prefix("0x")
                .filter(|hex| hex.len() % 2 == 0 && hex.bytes().all(|b| b.is_ascii_hexdigit()))
                .with_context(|| format!("`{text}` is not hex bytes to filter by"))?;
            format!("unhex('{hex}')")
        }
        ValueKind::Number => match ch_type {
            // A bound wider than any Decimal keeps the number as its text, so
            // it is compared as the number it spells rather than as text,
            // which orders "9" after "10".
            ChType::String if field_type == "BigInt" => literal(&integer_key(&integer(text)?)),
            ChType::String => format!(
                "toDecimal256({}, {TEXT_NUMBER_SCALE})",
                literal(number(text)?)
            ),
            // Decimals of two scales compare exactly, so the value keeps
            // every digit it has past the column's.
            ChType::Decimal { scale, .. } => {
                let text = number(text)?;
                format!(
                    "toDecimal256({}, {})",
                    literal(text),
                    decimal_scale(text, *scale)
                )
            }
            _ => number(text)?.to_string(),
        },
    })
}

/// The column as a filter compares it: a number kept as text is read as the
/// number it spells, and a list of them as the numbers they spell.
fn compared(column: &Column, kind: ValueKind) -> String {
    let name = quoted(&column.name);
    let as_number = |text: &str| match column.field.field_type.as_str() {
        "BigInt" => integer_order(text),
        _ => format!("toDecimal256OrNull({text}, {TEXT_NUMBER_SCALE})"),
    };
    match (kind, column.ch_type.base()) {
        (ValueKind::Number, ChType::String) => as_number(&name),
        (ValueKind::Number, ChType::Array(inner)) if *inner.base() == ChType::String => {
            format!("arrayMap(element -> {}, {name})", as_number("element"))
        }
        _ => name,
    }
}

/// A value: one element for a scalar column, the list's own for a list column.
fn value(column: &Column, condition: &Condition, value: &[Option<String>]) -> Result<String> {
    let render = |text: &Option<String>, ch_type: &ChType| match text {
        None => Ok("NULL".to_string()),
        Some(text) => element(text, condition.kind, &column.field.field_type, ch_type),
    };
    if condition.is_list {
        let ChType::Array(inner) = column.ch_type.base() else {
            bail!("`{}` is not a list column", column.row_name);
        };
        let inner = inner.base();
        Ok(format!(
            "[{}]",
            value
                .iter()
                .map(|text| render(text, inner))
                .collect::<Result<Vec<_>>>()?
                .join(", ")
        ))
    } else {
        match value {
            [text] => render(text, column.ch_type.base()),
            _ => bail!("A scalar filter takes one value"),
        }
    }
}

/// A list of text a String column is compared against, as rows of its own.
/// Anything else a value can be — NULL, a number read off text — is spelled
/// in the statement.
fn external_list(
    column: &Column,
    condition: &Condition,
    external: &mut Vec<External>,
) -> Option<String> {
    if condition.is_list
        || condition.kind != ValueKind::Text
        || *column.ch_type.base() != ChType::String
    {
        return None;
    }
    let mut rows = Vec::new();
    for value in &condition.values {
        let [Some(text)] = value.as_slice() else {
            return None;
        };
        super::row_binary::put_string(&mut rows, text);
    }
    let name = format!("envio_list_{}", external.len());
    external.push(External {
        name: name.clone(),
        rows,
    });
    Some(name)
}

/// A condition as the statement spells it. Given somewhere to put them, a list
/// of text goes beside the statement instead.
pub fn condition(
    table: &Table,
    condition: &Condition,
    external: Option<&mut Vec<External>>,
) -> Result<String> {
    let column = table.column(&condition.column).with_context(|| {
        format!(
            "\"{}\" has no column \"{}\" to filter by",
            table.entity.name, condition.column
        )
    })?;
    let compared = compared(column, condition.kind);
    Ok(match condition.operator {
        Operator::In if condition.values.is_empty() => "false".to_string(),
        Operator::In => {
            if let Some(list) =
                external.and_then(|external| external_list(column, condition, external))
            {
                return Ok(format!("{compared} IN {list}"));
            }
            let candidates = condition
                .values
                .iter()
                .map(|candidate| value(column, condition, candidate))
                .collect::<Result<Vec<_>>>()?;
            if condition.is_list {
                format!(
                    "({})",
                    candidates
                        .iter()
                        .map(|candidate| format!("{compared} = {candidate}"))
                        .collect::<Vec<_>>()
                        .join(" OR ")
                )
            } else {
                format!("{compared} IN ({})", candidates.join(", "))
            }
        }
        operator => {
            let [candidate] = condition.values.as_slice() else {
                bail!("A {operator:?} filter takes exactly one value");
            };
            let sql_operator = match operator {
                Operator::Gt => ">",
                Operator::Lt => "<",
                Operator::Gte => ">=",
                Operator::Lte => "<=",
                _ => "=",
            };
            format!(
                "{compared} {sql_operator} {}",
                value(column, condition, candidate)?
            )
        }
    })
}

fn conjunction(parts: &[String]) -> String {
    if parts.is_empty() {
        "true".to_string()
    } else {
        parts.join(" AND ")
    }
}

fn joined(columns: &[String]) -> String {
    columns
        .iter()
        .map(|column| quoted(column))
        .collect::<Vec<_>>()
        .join(", ")
}

/// A key tuple for `IN`, which ClickHouse spells without parentheses for one
/// column.
fn key_tuple(key: &[String]) -> String {
    match key {
        [column] => quoted(column),
        columns => format!("({})", joined(columns)),
    }
}

fn as_row_names(table: &Table) -> String {
    table
        .columns
        .iter()
        .map(|column| format!("{} AS {}", quoted(&column.name), quoted(&column.row_name)))
        .collect::<Vec<_>>()
        .join(", ")
}

/// The rows of `table` matching every condition, as of the frontier.
///
/// A condition on the entity's key narrows the history before the latest row of
/// each entity is picked, which is safe because every row of an entity shares
/// its key. Any other condition can only be judged on the latest row, so it
/// picks out the entities to read and is checked again on what they read as.
pub fn load(
    database: &str,
    table: &Table,
    conditions: &[Condition],
    frontier: &Frontier,
) -> Result<Read> {
    let mut external = Vec::new();
    let sql = load_sql(database, table, conditions, frontier, Some(&mut external))?;
    // Sent with its lists, the statement is a form field, which the server
    // reads no further than 128 KiB into. A long list of anything but text
    // is spelled in it all the same, and can outgrow one.
    if !external.is_empty() && sql.len() > MAX_FORM_FIELD {
        return Ok(Read {
            sql: load_sql(database, table, conditions, frontier, None)?,
            external: Vec::new(),
        });
    }
    Ok(Read { sql, external })
}

/// The longest form field the server reads, which no setting a request can
/// carry raises.
const MAX_FORM_FIELD: usize = 128 * 1024;

fn load_sql(
    database: &str,
    table: &Table,
    conditions: &[Condition],
    frontier: &Frontier,
    mut external: Option<&mut Vec<External>>,
) -> Result<String> {
    let entity = &table.entity;
    let key = entity.key();
    let mut on_key = Vec::new();
    let mut on_values = Vec::new();
    for filter in conditions {
        let rendered = condition(table, filter, external.as_deref_mut())?;
        let column = table
            .column(&filter.column)
            .map(|column| column.name.as_str());
        if column.is_some_and(|column| key.iter().any(|key| key == column)) {
            on_key.push(rendered);
        } else {
            on_values.push(rendered);
        }
    }
    let committed = format!(
        "{} <= {}",
        quoted(CHECKPOINT_ID_COLUMN),
        frontier_of(entity.chain_id_column.as_deref(), frontier)
    );
    let source = table_ref(database, &entity.history_table);
    let mut narrowing = on_key.clone();
    narrowing.push(committed.clone());
    if !on_values.is_empty() {
        let mut matching = on_key.clone();
        matching.extend(on_values.iter().cloned());
        matching.push(committed);
        narrowing.push(format!(
            "{} IN (SELECT {} FROM {source} WHERE {})",
            key_tuple(&key),
            joined(&key),
            conjunction(&matching)
        ));
    }
    // Every column the latest row carries besides the key, taken in one tuple
    // so they all come from the same row. Grouping on the key outruns sorting
    // each entity's rows to keep the first.
    let latest = table
        .columns
        .iter()
        .map(|column| column.name.as_str())
        .filter(|name| !key.iter().any(|key| key == name))
        .chain([CHANGE_COLUMN])
        .collect::<Vec<_>>();
    let untupled = latest
        .iter()
        .enumerate()
        .map(|(index, name)| format!("{LATEST}.{} AS {}", index + 1, quoted(name)))
        .collect::<Vec<_>>()
        .join(", ");
    let mut current = on_values;
    current.insert(0, format!("{} = {}", quoted(CHANGE_COLUMN), literal(SET)));
    Ok(format!(
        "SELECT {} FROM (SELECT {key}, {untupled} FROM (SELECT {key}, argMax(tuple({}), {}) AS \
         {LATEST} FROM {source} WHERE {} GROUP BY {key})) WHERE {} FORMAT RowBinary",
        as_row_names(table),
        latest
            .iter()
            .map(|name| quoted(name))
            .collect::<Vec<_>>()
            .join(", "),
        quoted(CHECKPOINT_ID_COLUMN),
        conjunction(&narrowing),
        conjunction(&current),
        key = joined(&key),
    ))
}

/// What a load names each entity's latest row by. Not a column's name: an
/// entity field can't start with `envio_`.
const LATEST: &str = "envio_latest";

/// The entities a rollback reaches: any with a row above its bound.
fn changed(database: &str, table: &Table, above: &str) -> String {
    let key = table.entity.key();
    format!(
        "{} IN (SELECT {} FROM {} WHERE {above})",
        key_tuple(&key),
        joined(&key),
        table_ref(database, &table.entity.history_table)
    )
}

/// The entities a rollback removes: every row they have is above the bound, so
/// nothing of them existed at the target.
pub fn rollback_removed(database: &str, table: &Table, bounds: &Bounds) -> Result<String> {
    let entity = &table.entity;
    let above = above(
        bounds,
        entity.chain_id_column.as_deref(),
        CHECKPOINT_ID_COLUMN,
    )?;
    let key = entity.key();
    let as_row_names = key
        .iter()
        .map(|column| {
            let row_name = table
                .columns
                .iter()
                .find(|candidate| &candidate.name == column)
                .map_or(column.as_str(), |candidate| candidate.row_name.as_str());
            format!("{} AS {}", quoted(column), quoted(row_name))
        })
        .collect::<Vec<_>>()
        .join(", ");
    Ok(format!(
        "SELECT {as_row_names} FROM {} WHERE {} GROUP BY {} HAVING countIf(NOT ({above})) = 0 \
         FORMAT RowBinary",
        table_ref(database, &entity.history_table),
        changed(database, table, &above),
        joined(&key)
    ))
}

/// The row each entity a rollback reaches held at the target — set or deleted.
pub fn rollback_restored(database: &str, table: &Table, bounds: &Bounds) -> Result<String> {
    let entity = &table.entity;
    let above = above(
        bounds,
        entity.chain_id_column.as_deref(),
        CHECKPOINT_ID_COLUMN,
    )?;
    let key = entity.key();
    let columns = joined(
        &table
            .columns
            .iter()
            .map(|column| column.name.clone())
            .collect::<Vec<_>>(),
    );
    Ok(format!(
        "SELECT {}, {change} FROM (SELECT {columns}, {change} FROM {} WHERE {} AND NOT ({above}) \
         ORDER BY {}, {} DESC LIMIT 1 BY {}) FORMAT RowBinary",
        as_row_names(table),
        table_ref(database, &entity.history_table),
        changed(database, table, &above),
        joined(&key),
        quoted(CHECKPOINT_ID_COLUMN),
        joined(&key),
        change = quoted(CHANGE_COLUMN),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clickhouse::table::test_support::{account, per_chain_account};
    use pretty_assertions::assert_eq;

    fn eq(column: &str, kind: ValueKind, value: &str) -> Condition {
        Condition {
            column: column.to_string(),
            operator: Operator::Eq,
            values: vec![vec![Some(value.to_string())]],
            kind,
            is_list: false,
            enum_name: None,
            is_chain_id: false,
        }
    }

    fn frontier(entries: &[(i64, i64)]) -> Frontier {
        entries.iter().copied().collect()
    }

    /// A load by id narrows the history by the primary key before picking each
    /// entity's latest row, and asks for nothing past the frontier. The ids go
    /// beside the statement, each as a RowBinary string.
    #[test]
    fn a_load_by_id_narrows_on_the_key() {
        let mut by_ids = eq("id", ValueKind::Text, "a");
        by_ids.operator = Operator::In;
        by_ids.values = vec![vec![Some("a".to_string())], vec![Some("b'c".to_string())]];
        assert_eq!(
            load("db", &account(), &[by_ids], &frontier(&[(1, 7)])).unwrap(),
            Read {
                sql: "SELECT `id` AS `id`, `owner_name` AS `ownerName`, `balance` AS `balance` \
                      FROM (SELECT `id`, envio_latest.1 AS `owner_name`, envio_latest.2 AS \
                      `balance`, envio_latest.3 AS `envio_change` FROM (SELECT `id`, \
                      argMax(tuple(`owner_name`, `balance`, `envio_change`), \
                      `envio_checkpoint_id`) AS envio_latest FROM `db`.`envio_history_Account` \
                      WHERE `id` IN envio_list_0 AND `envio_checkpoint_id` <= 7 GROUP BY `id`)) \
                      WHERE `envio_change` = 'SET' FORMAT RowBinary"
                    .to_string(),
                external: vec![External {
                    name: "envio_list_0".to_string(),
                    rows: b"\x01a\x03b'c".to_vec(),
                }],
            }
        );
    }

    /// Only a list of text goes beside the statement: a NULL has no row to be,
    /// and a number kept as text is compared as the number it spells.
    #[test]
    fn a_list_with_anything_but_text_is_spelled_in_the_statement() {
        let mut with_null = eq("ownerName", ValueKind::Text, "a");
        with_null.operator = Operator::In;
        with_null.values = vec![vec![Some("a".to_string())], vec![None]];
        let mut numbers = eq("balance", ValueKind::Number, "1");
        numbers.operator = Operator::In;
        let mut external = Vec::new();
        assert_eq!(
            (
                condition(&account(), &with_null, Some(&mut external)).unwrap(),
                condition(&account(), &numbers, Some(&mut external)).unwrap(),
                external,
            ),
            (
                "`owner_name` IN ('a', NULL)".to_string(),
                format!("{} IN ('1000011')", integer_order("`balance`")),
                Vec::new(),
            )
        );
    }

    /// A value condition can only be judged on an entity's latest row: an
    /// entity whose older row matches must not come back. So it picks the
    /// candidates, and is checked again once they are resolved.
    #[test]
    fn a_load_by_value_checks_the_latest_row() {
        assert_eq!(
            load(
                "db",
                &account(),
                &[eq("ownerName", ValueKind::Text, "alice")],
                &frontier(&[(1, 7)])
            )
            .unwrap()
            .sql,
            "SELECT `id` AS `id`, `owner_name` AS `ownerName`, `balance` AS `balance` FROM \
             (SELECT `id`, envio_latest.1 AS `owner_name`, envio_latest.2 AS `balance`, \
             envio_latest.3 AS `envio_change` FROM (SELECT `id`, argMax(tuple(`owner_name`, \
             `balance`, `envio_change`), `envio_checkpoint_id`) AS envio_latest FROM \
             `db`.`envio_history_Account` WHERE `envio_checkpoint_id` <= 7 AND `id` IN (SELECT \
             `id` FROM `db`.`envio_history_Account` WHERE `owner_name` = 'alice' AND \
             `envio_checkpoint_id` <= 7) GROUP BY `id`)) WHERE `envio_change` = 'SET' AND \
             `owner_name` = 'alice' FORMAT RowBinary"
        );
    }

    /// A per-chain entity's row compares against its own chain's frontier, and
    /// the chain is part of what names it.
    #[test]
    fn a_per_chain_load_holds_each_row_to_its_chains_frontier() {
        let mut on_chain = eq("chainId", ValueKind::Number, "137");
        on_chain.is_chain_id = true;
        assert_eq!(
            load(
                "db",
                &per_chain_account(),
                &[eq("id", ValueKind::Text, "a"), on_chain],
                &frontier(&[(1, 7), (137, 9)])
            )
            .unwrap()
            .sql,
            "SELECT `id` AS `id`, `chain_id` AS `chainId` FROM (SELECT `id`, `chain_id`, \
             envio_latest.1 AS `envio_change` FROM (SELECT `id`, `chain_id`, \
             argMax(tuple(`envio_change`), `envio_checkpoint_id`) AS envio_latest FROM \
             `db`.`envio_history_Account` WHERE `id` = 'a' AND `chain_id` = 137 AND \
             `envio_checkpoint_id` <= multiIf(`chain_id` = 1, 7, `chain_id` = 137, 9, 0) GROUP \
             BY `id`, `chain_id`)) WHERE `envio_change` = 'SET' FORMAT RowBinary"
        );
    }

    #[test]
    fn a_value_that_could_break_out_of_the_statement_is_refused() {
        let refused = [
            eq("balance", ValueKind::Number, "1 OR 1=1"),
            eq("id", ValueKind::Bytes, "0x0g"),
            eq("id", ValueKind::Boolean, "yes"),
        ]
        .map(|filter| {
            condition(&account(), &filter, None)
                .err()
                .map(|error| error.to_string())
        });
        assert_eq!(
            refused,
            [
                Some("`1 OR 1=1` is not an integer to filter by".to_string()),
                Some("`0x0g` is not hex bytes to filter by".to_string()),
                Some("`yes` is not a boolean to filter by".to_string()),
            ]
        );
    }

    /// A Decimal256 holds 76 digits between its whole part and its scale, so
    /// a value keeps every fractional digit it has only as far as its whole
    /// part leaves room: a scale past that is refused by the server, failing
    /// the whole load.
    #[test]
    fn a_decimal_value_keeps_its_digits_as_far_as_a_decimal_holds_them() {
        assert_eq!(
            [
                ("1.555", 2),
                ("1.5", 2),
                (&format!("1.{}", "5".repeat(80)), 2),
                ("12345678901234567.5", 60),
                ("1.5e3", 2),
                ("15e-3", 2),
                ("-0.5", 2),
            ]
            .map(|(text, scale)| decimal_scale(text, scale)),
            [3, 2, 75, 59, 2, 3, 2]
        );
    }

    /// A number kept as text is compared as the number it spells, on both
    /// sides.
    #[test]
    fn a_number_kept_as_text_is_compared_as_a_number() {
        let mut gt = eq("balance", ValueKind::Number, "10");
        gt.operator = Operator::Gt;
        assert_eq!(
            condition(&account(), &gt, None).unwrap(),
            format!("{} > '10000210'", integer_order("`balance`"))
        );
    }

    /// The key orders integers as numbers across signs and sizes, uint256's
    /// top past 2^255 included, and spells each one value the one way.
    #[test]
    fn an_integer_key_orders_as_the_number() {
        let max = "115792089237316195423570985008687907853269984665640564039457584007913129639935";
        let ordered = [
            "-1000", "-999", "-10", "-9", "-1", "0", "1", "9", "10", "999", max,
        ];
        let mut keys = ordered
            .iter()
            .map(|text| (integer_key(&integer(text).unwrap()), *text))
            .collect::<Vec<_>>();
        keys.sort();
        assert_eq!(
            (
                keys.iter().map(|(_, text)| *text).collect::<Vec<_>>(),
                ["-007", "0", "-0", "+1"].map(|text| integer(text).map_err(|e| e.to_string())),
            ),
            (
                ordered.to_vec(),
                [
                    Ok("-7".to_string()),
                    Ok("0".to_string()),
                    Ok("0".to_string()),
                    Err("`+1` is not an integer to filter by".to_string()),
                ]
            )
        );
    }

    #[test]
    fn rollback_reads_reach_only_what_a_bound_put_above_it() {
        let bounds = Bounds {
            sequence: Sequence::SharedAcrossChains,
            chain_ids: vec![1, 137],
            checkpoint_ids: vec![9, 4],
        };
        assert_eq!(
            (
                rollback_removed("db", &account(), &bounds).unwrap(),
                rollback_restored("db", &account(), &bounds).unwrap()
            ),
            (
                "SELECT `id` AS `id` FROM `db`.`envio_history_Account` WHERE `id` IN (SELECT \
                 `id` FROM `db`.`envio_history_Account` WHERE `envio_checkpoint_id` > 4) GROUP \
                 BY `id` HAVING countIf(NOT (`envio_checkpoint_id` > 4)) = 0 FORMAT RowBinary"
                    .to_string(),
                "SELECT `id` AS `id`, `owner_name` AS `ownerName`, `balance` AS `balance`, \
                 `envio_change` FROM (SELECT `id`, `owner_name`, `balance`, `envio_change` FROM \
                 `db`.`envio_history_Account` WHERE `id` IN (SELECT `id` FROM \
                 `db`.`envio_history_Account` WHERE `envio_checkpoint_id` > 4) AND NOT \
                 (`envio_checkpoint_id` > 4) ORDER BY `id`, `envio_checkpoint_id` DESC LIMIT 1 \
                 BY `id`) FORMAT RowBinary"
                    .to_string()
            )
        );
    }

    #[test]
    fn per_chain_bounds_name_each_chain() {
        let bounds = Bounds {
            sequence: Sequence::PerChain,
            chain_ids: vec![1, 137],
            checkpoint_ids: vec![9, 4],
        };
        assert_eq!(
            (
                above(&bounds, Some("chain_id"), "id").unwrap(),
                above(&bounds, None, "id")
                    .err()
                    .map(|error| error.to_string().contains("no chain-id column")),
            ),
            (
                "((`chain_id` = 1 AND `id` > 9) OR (`chain_id` = 137 AND `id` > 4))".to_string(),
                Some(true)
            )
        );
    }

    #[test]
    fn numbers_are_recognised_by_their_spelling_alone() {
        assert_eq!(
            ["1", "-1.5", "1e21", "2.5E-3", "", "-", "1.", ".5", "0x1", "1e"].map(is_number),
            [true, true, true, true, false, false, false, false, false, false]
        );
    }
}
