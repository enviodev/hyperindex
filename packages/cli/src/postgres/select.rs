//! The statement a get or getWhere loads its rows with in Postgres.

use anyhow::{anyhow, Result};

use crate::entity_filter::{Condition, Operator};

use super::internal::quote_ident;
use super::param::Param;
use super::storage::array_literal;

pub fn load_query(
    pg_schema: &str,
    table_name: &str,
    conditions: Vec<Condition>,
) -> Result<(String, Vec<Param>)> {
    let mut params = Vec::new();
    let mut bind = |param: Param| {
        params.push(param);
        format!("${}", params.len())
    };
    let mut parts = Vec::with_capacity(conditions.len());
    for condition in conditions {
        let column = quote_ident(&condition.column);
        let part = match condition.operator {
            // Postgres prunes a cached plan's partitions only on a constant in
            // the statement, so a per-chain entity's chain id is written in
            // rather than bound. Bound, the planner re-plans every execution
            // instead: 315us per load against 218us written in, measured on 30
            // chains. The cost is a cached statement per chain rather than per
            // filter shape, about 8KB of plan cache each.
            Operator::Eq if condition.is_chain_id => {
                let chain_id = match condition.values.as_slice() {
                    [value] => match value.as_slice() {
                        [Some(text)] => text.parse::<u64>().ok(),
                        _ => None,
                    },
                    _ => None,
                }
                .ok_or_else(|| anyhow!("A chain filter takes one whole-number chain id"))?;
                format!("{column} = {chain_id}")
            }
            // Postgres arrays are rectangular, so lists of different lengths
            // can't share one bound array: one equality each instead.
            Operator::In if condition.is_list => {
                if condition.values.is_empty() {
                    "FALSE".to_string()
                } else {
                    let equalities = condition
                        .values
                        .into_iter()
                        .map(|list| format!("{column} = {}", bind(array_literal(list))))
                        .collect::<Vec<_>>();
                    format!("({})", equalities.join(" OR "))
                }
            }
            Operator::In => {
                let candidates = bind(array_literal(condition.values.into_iter().map(scalar)));
                match condition.enum_name {
                    // A bound array of strings is `text[]`, which has no
                    // equality with an enum.
                    Some(enum_name) => format!(
                        "{column} = ANY({candidates}::TEXT[]::{}.{enum_name}[])",
                        quote_ident(pg_schema)
                    ),
                    None => format!("{column} = ANY({candidates})"),
                }
            }
            operator => {
                let [value] = <[Vec<Option<String>>; 1]>::try_from(condition.values)
                    .map_err(|_| anyhow!("A {operator:?} filter takes exactly one value"))?;
                let placeholder = bind(if condition.is_list {
                    array_literal(value)
                } else {
                    match scalar(value) {
                        Some(text) => Param::Text(text),
                        None => Param::Null,
                    }
                });
                let sql_operator = match operator {
                    Operator::Gt => ">",
                    Operator::Lt => "<",
                    Operator::Gte => ">=",
                    Operator::Lte => "<=",
                    _ => "=",
                };
                format!("{column} {sql_operator} {placeholder}")
            }
        };
        parts.push(part);
    }
    let condition = if parts.is_empty() {
        "TRUE".to_string()
    } else {
        parts.join(" AND ")
    };
    Ok((
        format!(
            "SELECT * FROM {}.{} WHERE {condition};",
            quote_ident(pg_schema),
            quote_ident(table_name)
        ),
        params,
    ))
}

fn scalar(value: Vec<Option<String>>) -> Option<String> {
    value.into_iter().next().flatten()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn condition(column: &str, operator: Operator, values: &[&[&str]]) -> Condition {
        Condition {
            column: column.to_string(),
            operator,
            values: values
                .iter()
                .map(|value| value.iter().map(|text| Some(text.to_string())).collect())
                .collect(),
            is_list: false,
            enum_name: None,
            is_chain_id: false,
        }
    }

    #[test]
    fn every_operator_renders_against_its_column() {
        let (sql, params) = load_query(
            "public",
            "Token",
            vec![
                condition("owner", Operator::Eq, &[&["0xa"]]),
                condition("amount", Operator::Gte, &[&["10"]]),
                condition("id", Operator::In, &[&["a"], &["b\"c"]]),
                Condition {
                    enum_name: Some("Kind".to_string()),
                    ..condition("kind", Operator::In, &[&["ALPHA"]])
                },
                Condition {
                    is_list: true,
                    ..condition("tags", Operator::In, &[&["x"], &["x", "y"]])
                },
                Condition {
                    is_list: true,
                    ..condition("empty", Operator::In, &[])
                },
                Condition {
                    is_list: true,
                    ..condition("path", Operator::Lt, &[&["a", "b"]])
                },
                Condition {
                    is_chain_id: true,
                    ..condition("chain_id", Operator::Eq, &[&["137"]])
                },
            ],
        )
        .unwrap();
        assert_eq!(
            (sql, params),
            (
                "SELECT * FROM \"public\".\"Token\" WHERE \"owner\" = $1 AND \"amount\" >= $2 \
                 AND \"id\" = ANY($3) AND \"kind\" = ANY($4::TEXT[]::\"public\".Kind[]) \
                 AND (\"tags\" = $5 OR \"tags\" = $6) AND FALSE AND \"path\" < $7 \
                 AND \"chain_id\" = 137;"
                    .to_string(),
                vec![
                    Param::Text("0xa".to_string()),
                    Param::Text("10".to_string()),
                    Param::Text("{\"a\",\"b\\\"c\"}".to_string()),
                    Param::Text("{\"ALPHA\"}".to_string()),
                    Param::Text("{\"x\"}".to_string()),
                    Param::Text("{\"x\",\"y\"}".to_string()),
                    Param::Text("{\"a\",\"b\"}".to_string()),
                ]
            )
        );
    }

    /// The chain id is the one value written into the statement, so nothing but
    /// digits may reach it.
    #[test]
    fn a_chain_id_that_is_not_a_number_is_refused() {
        let refused = load_query(
            "public",
            "Token",
            vec![Condition {
                is_chain_id: true,
                ..condition("chain_id", Operator::Eq, &[&["1; DROP"]])
            }],
        )
        .err()
        .map(|error| error.to_string());
        assert_eq!(
            refused,
            Some("A chain filter takes one whole-number chain id".to_string())
        );
    }
}
