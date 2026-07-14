use super::bool_exp::coerce_bool_exp;
use super::coerce::{
    coerce_column_value, coerce_enum, coerce_limit, coerce_offset, coerce_string_strict,
    parse_json_path,
};
use super::selection::Flat;
use super::{
    found_desc, ir, model_table, q, verr, Ctx, FieldDef, GResult, Json, Table, TypeRef, V,
};

// ---------------------------------------------------------------------------
// Argument coercion: select args, by_pk, stream
// ---------------------------------------------------------------------------

/// Looks up a provided argument and resolves variables against the
/// argument's declared type. Returns None when the argument was not given.
pub(super) fn resolve_arg<'a>(
    ctx: &'a Ctx<'a>,
    flat: &Flat<'a>,
    field: &FieldDef,
    name: &str,
    field_path: &str,
) -> GResult<Option<V<'a>>> {
    let Some((_, raw)) = flat.args.iter().find(|(n, _)| n == name) else {
        return Ok(None);
    };
    let ivd = field
        .args
        .iter()
        .find(|a| a.name == name)
        .expect("argument definition must exist after unknown-arg check");
    let path = format!("{field_path}.args.{name}");
    Ok(Some(ctx.resolve(
        raw,
        &ivd.ty,
        ivd.default_value.is_some(),
        &path,
    )?))
}

pub(super) fn coerce_select_args<'a>(
    ctx: &'a Ctx<'a>,
    flat: &Flat<'a>,
    field: &FieldDef,
    table_name: &str,
    field_path: &str,
    clamp: bool,
) -> GResult<ir::SelectArgs> {
    let table = model_table(ctx, table_name);
    let mut args = ir::SelectArgs::default();

    if let Some(v) = resolve_arg(ctx, flat, field, "where", field_path)? {
        if !v.is_null() {
            let path = format!("{field_path}.args.where");
            args.where_ = Some(coerce_bool_exp(ctx, table_name, v, &path)?);
        }
    }
    if let Some(v) = resolve_arg(ctx, flat, field, "order_by", field_path)? {
        if !v.is_null() {
            let path = format!("{field_path}.args.order_by");
            args.order_by = coerce_order_by(ctx, table_name, v, &path)?;
        }
    }
    if let Some(v) = resolve_arg(ctx, flat, field, "distinct_on", field_path)? {
        if !v.is_null() {
            let enum_name = format!("{table_name}_select_column");
            for (i, item) in list_items(v).into_iter().enumerate() {
                let ipath = format!("{field_path}.args.distinct_on[{i}]");
                let api = coerce_enum(ctx, item, &enum_name, &ipath)?;
                args.distinct_on.push(api_to_db_column(table, &api));
            }
        }
    }
    if let Some(v) = resolve_arg(ctx, flat, field, "limit", field_path)? {
        args.limit = coerce_limit(ctx, v, &format!("{field_path}.args.limit"))?;
    }
    if let Some(v) = resolve_arg(ctx, flat, field, "offset", field_path)? {
        args.offset = coerce_offset(ctx, v, &format!("{field_path}.args.offset"))?;
    }

    if !args.distinct_on.is_empty() && !args.order_by.is_empty() {
        // Hasura: the first N order_by entries (N = distinct_on length,
        // duplicates included) must all be plain columns and must contain
        // every distinct_on column.
        let n = args.distinct_on.len();
        let initial: Vec<&str> = args
            .order_by
            .iter()
            .take(n)
            .filter_map(|item| match &item.target {
                ir::OrderTarget::Column { column } => Some(column.as_str()),
                _ => None,
            })
            .collect();
        let matches = initial.len() == n
            && args
                .distinct_on
                .iter()
                .all(|c| initial.contains(&c.as_str()));
        if !matches {
            return Err(verr(
                format!("{field_path}.args"),
                "\"distinct_on\" columns must match initial \"order_by\" columns",
            ));
        }
    }

    if clamp {
        if let Some(n) = ctx.response_limit {
            args.limit = Some(args.limit.map_or(n, |l| l.min(n)));
        }
    }
    Ok(args)
}

pub(super) fn coerce_by_pk_args<'a>(
    ctx: &'a Ctx<'a>,
    flat: &Flat<'a>,
    field: &FieldDef,
    table_name: &str,
    field_path: &str,
) -> GResult<Vec<(String, ir::SqlValue)>> {
    let table = model_table(ctx, table_name);
    let mut pk: Vec<(String, ir::SqlValue)> = Vec::new();
    for arg in &field.args {
        let path = format!("{field_path}.args.{}", arg.name);
        let Some(v) = resolve_arg(ctx, flat, field, &arg.name, field_path)? else {
            return Err(verr(path, format!("missing required field '{}'", arg.name)));
        };
        let col = table
            .column_by_api_name(&arg.name)
            .expect("by_pk argument must be a table column");
        let value = coerce_column_value(ctx, col.scalar, &col.pg_type, col.is_array, v, &path)?;
        pk.push((col.db_name.clone(), value));
    }
    Ok(pk)
}

pub(super) fn coerce_stream_args<'a>(
    ctx: &'a Ctx<'a>,
    flat: &Flat<'a>,
    field: &FieldDef,
    table_name: &str,
    field_path: &str,
) -> GResult<(i64, Vec<ir::StreamCursor>, Option<ir::BoolExp>)> {
    let batch_path = format!("{field_path}.args.batch_size");
    let mut batch_size = match resolve_arg(ctx, flat, field, "batch_size", field_path)? {
        Some(v) => coerce_limit(ctx, v, &batch_path)?
            .ok_or_else(|| verr(&batch_path, "unexpected null value for type 'Int'"))?,
        None => return Err(verr(batch_path, "missing required field 'batch_size'")),
    };
    if let Some(n) = ctx.response_limit {
        batch_size = batch_size.min(n);
    }

    let cursor_path = format!("{field_path}.args.cursor");
    let Some(cursor_v) = resolve_arg(ctx, flat, field, "cursor", field_path)? else {
        return Err(verr(cursor_path, "missing required field 'cursor'"));
    };
    let mut cursor: Vec<ir::StreamCursor> = Vec::new();
    let table = model_table(ctx, table_name);
    for (i, item) in expect_list(cursor_v, &cursor_path)?.into_iter().enumerate() {
        if item.is_null() {
            continue;
        }
        let ipath = format!("{cursor_path}[{i}]");
        let input_type = format!("{table_name}_stream_cursor_input");
        let entries = expect_object(item, &input_type, &ipath)?;
        let type_def = ctx.registry.get(&input_type);
        let mut initial: Option<V> = None;
        let mut descending = false;
        for &(key, value) in &entries {
            let Some(fd) = type_def.and_then(|d| d.input_field(key)) else {
                return Err(verr(
                    format!("{ipath}.{key}"),
                    format!("field '{key}' not found in type: '{input_type}'"),
                ));
            };
            let vpath = format!("{ipath}.{key}");
            let v = resolve_nested(ctx, value, &fd.ty, fd.default_value.is_some(), &vpath)?;
            match key {
                "initial_value" => initial = Some(v),
                "ordering" if !v.is_null() => {
                    let dir = coerce_enum(ctx, v, "cursor_ordering", &vpath)?;
                    descending = dir == "DESC";
                }
                _ => {}
            }
        }
        let init_path = format!("{ipath}.initial_value");
        let Some(initial) = initial else {
            return Err(verr(init_path, "missing required field 'initial_value'"));
        };
        let value_type = format!("{table_name}_stream_cursor_value_input");
        let value_def = ctx.registry.get(&value_type);
        let cols = expect_object(initial, &value_type, &init_path)?;
        for (key, value) in ordered_keys(table, cols) {
            let Some(fd) = value_def.and_then(|d| d.input_field(key)) else {
                return Err(verr(
                    format!("{init_path}.{key}"),
                    format!("field '{key}' not found in type: '{value_type}'"),
                ));
            };
            let vpath = format!("{init_path}.{key}");
            let v = resolve_nested(ctx, value, &fd.ty, fd.default_value.is_some(), &vpath)?;
            let col = table
                .column_by_api_name(key)
                .expect("cursor value input field must be a table column");
            let initial_value = if v.is_null() {
                None
            } else {
                Some(coerce_column_value(
                    ctx,
                    col.scalar,
                    &col.pg_type,
                    col.is_array,
                    v,
                    &vpath,
                )?)
            };
            cursor.push(ir::StreamCursor {
                column: col.db_name.clone(),
                scalar: col.scalar,
                pg_type: col.pg_type.clone(),
                is_array: col.is_array,
                initial_value,
                descending,
            });
        }
    }
    if cursor.is_empty() {
        return Err(verr(
            format!("{field_path}.args"),
            "one streaming column field is expected",
        ));
    }

    let mut where_ = None;
    if let Some(v) = resolve_arg(ctx, flat, field, "where", field_path)? {
        if !v.is_null() {
            let path = format!("{field_path}.args.where");
            where_ = Some(coerce_bool_exp(ctx, table_name, v, &path)?);
        }
    }
    Ok((batch_size, cursor, where_))
}

/// json/jsonb column `path` argument.
pub(super) fn coerce_json_path_arg<'a>(
    ctx: &'a Ctx<'a>,
    flat: &Flat<'a>,
    field: &FieldDef,
    field_path: &str,
) -> GResult<Option<Vec<String>>> {
    let Some(v) = resolve_arg(ctx, flat, field, "path", field_path)? else {
        return Ok(None);
    };
    let text = coerce_string_strict(v, &format!("{field_path}.args.path"))?;
    match parse_json_path(&text) {
        Ok(segments) => Ok(if segments.is_empty() {
            None
        } else {
            Some(segments)
        }),
        Err(()) => Err(verr(
            format!("{field_path}.args"),
            format!(
                "parse json path error: {text}. Accept letters, digits, underscore (_) or hyphen (-) only. Use quotes enclosed in bracket ([\"...\"]) if there is any special character"
            ),
        )),
    }
}

// ---------------------------------------------------------------------------
// Nested value plumbing
// ---------------------------------------------------------------------------

/// Resolves one nesting level: literals may contain variables, JSON values
/// stay JSON all the way down.
pub(super) fn resolve_nested<'a>(
    ctx: &'a Ctx<'a>,
    v: V<'a>,
    loc_ty: &TypeRef,
    loc_has_default: bool,
    path: &str,
) -> GResult<V<'a>> {
    match v {
        V::L(l) => ctx.resolve(l, loc_ty, loc_has_default, path),
        j => Ok(j),
    }
}

/// List coercion: single non-null values coerce to one-element lists.
pub(super) fn list_items<'a>(v: V<'a>) -> Vec<V<'a>> {
    match v {
        V::L(q::Value::List(items)) => items.iter().map(V::L).collect(),
        V::J(Json::Array(items)) => items.iter().map(V::J).collect(),
        single => vec![single],
    }
}

pub(super) fn expect_list<'a>(v: V<'a>, path: &str) -> GResult<Vec<V<'a>>> {
    if v.is_null() {
        return Err(verr(path, "expected a list, but found null"));
    }
    Ok(list_items(v))
}

/// Sorted (key, value) entries of an input object, with the standard
/// "expected an object" error otherwise.
pub(super) fn expect_object<'a>(
    v: V<'a>,
    type_name: &str,
    path: &str,
) -> GResult<Vec<(&'a str, V<'a>)>> {
    match v {
        V::L(q::Value::Object(map)) => {
            Ok(map.iter().map(|(k, val)| (k.as_str(), V::L(val))).collect())
        }
        V::J(Json::Object(map)) => Ok(map.iter().map(|(k, val)| (k.as_str(), V::J(val))).collect()),
        other => Err(verr(
            path,
            format!(
                "expected an object for type '{type_name}', but found {}",
                found_desc(other)
            ),
        )),
    }
}

/// Reorders input-object keys: primary-key columns first (in key order),
/// then the rest alphabetically. Hasura's processing order is its HashMap's
/// hash order, which cannot be reproduced; this matches every order the
/// oracle snapshots pin.
fn ordered_keys<'a>(table: &Table, entries: Vec<(&'a str, V<'a>)>) -> Vec<(&'a str, V<'a>)> {
    let pk_apis: Vec<&str> = table
        .primary_key
        .iter()
        .filter_map(|db| table.columns.iter().find(|c| &c.db_name == db))
        .map(|c| c.api_name.as_str())
        .collect();
    let mut front: Vec<(&str, V)> = Vec::new();
    let mut rest: Vec<(&str, V)> = Vec::new();
    for entry in entries {
        if pk_apis.contains(&entry.0) {
            front.push(entry);
        } else {
            rest.push(entry);
        }
    }
    front.sort_by_key(|(k, _)| pk_apis.iter().position(|p| p == k));
    front.extend(rest);
    front
}

pub(super) fn api_to_db_column(table: &Table, api_name: &str) -> String {
    table
        .column_by_api_name(api_name)
        .map(|c| c.db_name.clone())
        .unwrap_or_else(|| api_name.to_string())
}

// ---------------------------------------------------------------------------
// order_by coercion
// ---------------------------------------------------------------------------

fn order_direction(name: &str) -> ir::OrderDirection {
    match name {
        "asc" => ir::OrderDirection::Asc,
        "asc_nulls_first" => ir::OrderDirection::AscNullsFirst,
        "asc_nulls_last" => ir::OrderDirection::AscNullsLast,
        "desc" => ir::OrderDirection::Desc,
        "desc_nulls_first" => ir::OrderDirection::DescNullsFirst,
        _ => ir::OrderDirection::DescNullsLast,
    }
}

fn coerce_order_by<'a>(
    ctx: &'a Ctx<'a>,
    table_name: &str,
    v: V<'a>,
    base_path: &str,
) -> GResult<Vec<ir::OrderByItem>> {
    let mut out: Vec<ir::OrderByItem> = Vec::new();
    let elem_ty = TypeRef::non_null(TypeRef::named(&format!("{table_name}_order_by")));
    for (i, item) in list_items(v).into_iter().enumerate() {
        let ipath = format!("{base_path}[{i}]");
        let item = resolve_item(ctx, item, &elem_ty, &ipath)?;
        let mut chain: Vec<(String, String)> = Vec::new();
        expand_order_object(ctx, table_name, item, &ipath, &mut chain, &mut out)?;
    }
    Ok(out)
}

pub(super) fn resolve_item<'a>(
    ctx: &'a Ctx<'a>,
    v: V<'a>,
    elem_ty: &TypeRef,
    path: &str,
) -> GResult<V<'a>> {
    match v {
        V::L(l) => ctx.resolve(l, elem_ty, false, path),
        j => Ok(j),
    }
}

fn expand_order_object<'a>(
    ctx: &'a Ctx<'a>,
    table_name: &str,
    v: V<'a>,
    path: &str,
    chain: &mut Vec<(String, String)>,
    out: &mut Vec<ir::OrderByItem>,
) -> GResult<()> {
    let type_name = format!("{table_name}_order_by");
    let entries = expect_object(v, &type_name, path)?;
    let table = model_table(ctx, table_name);
    let type_def = ctx.registry.get(&type_name);
    for (key, value) in ordered_keys(table, entries) {
        let kpath = format!("{path}.{key}");
        let Some(fd) = type_def.and_then(|d| d.input_field(key)) else {
            return Err(verr(
                kpath,
                format!("field '{key}' not found in type: '{type_name}'"),
            ));
        };
        let value = resolve_nested(ctx, value, &fd.ty, fd.default_value.is_some(), &kpath)?;
        if value.is_null() {
            continue;
        }
        if let Some(col) = table.column_by_api_name(key) {
            let dir = coerce_enum(ctx, value, "order_by", &kpath)?;
            let target = if chain.is_empty() {
                ir::OrderTarget::Column {
                    column: col.db_name.clone(),
                }
            } else {
                ir::OrderTarget::ObjectRelColumn {
                    path: chain.clone(),
                    column: col.db_name.clone(),
                }
            };
            out.push(ir::OrderByItem {
                target,
                direction: order_direction(&dir),
            });
        } else if let Some(rel) = table.object_relationships.iter().find(|r| r.name == key) {
            chain.push((rel.local_db_column.clone(), rel.remote_table.clone()));
            expand_order_object(ctx, &rel.remote_table, value, &kpath, chain, out)?;
            chain.pop();
        } else if let Some(rel) = key
            .strip_suffix("_aggregate")
            .and_then(|base| table.array_relationships.iter().find(|r| r.name == base))
        {
            expand_aggregate_order(ctx, rel, value, &kpath, chain, out)?;
        } else {
            return Err(verr(
                kpath,
                format!("field '{key}' not found in type: '{type_name}'"),
            ));
        }
    }
    Ok(())
}

fn expand_aggregate_order<'a>(
    ctx: &'a Ctx<'a>,
    rel: &crate::serve::model::ArrayRelationship,
    v: V<'a>,
    path: &str,
    chain: &[(String, String)],
    out: &mut Vec<ir::OrderByItem>,
) -> GResult<()> {
    let remote = model_table(ctx, &rel.remote_table);
    let type_name = format!("{}_aggregate_order_by", rel.remote_table);
    let type_def = ctx.registry.get(&type_name);
    for (op, value) in expect_object(v, &type_name, path)? {
        let opath = format!("{path}.{op}");
        let Some(fd) = type_def.and_then(|d| d.input_field(op)) else {
            return Err(verr(
                opath,
                format!("field '{op}' not found in type: '{type_name}'"),
            ));
        };
        let value = resolve_nested(ctx, value, &fd.ty, fd.default_value.is_some(), &opath)?;
        if value.is_null() {
            continue;
        }
        if op == "count" {
            let dir = coerce_enum(ctx, value, "order_by", &opath)?;
            out.push(ir::OrderByItem {
                target: ir::OrderTarget::ArrayRelAggregate {
                    path: chain.to_vec(),
                    remote_column: rel.remote_db_column.clone(),
                    remote_table: rel.remote_table.clone(),
                    op: "count".to_string(),
                    column: None,
                },
                direction: order_direction(&dir),
            });
        } else {
            let col_type = format!("{}_{op}_order_by", rel.remote_table);
            let col_def = ctx.registry.get(&col_type);
            for (col_key, col_value) in expect_object(value, &col_type, &opath)? {
                let cpath = format!("{opath}.{col_key}");
                let Some(cfd) = col_def.and_then(|d| d.input_field(col_key)) else {
                    return Err(verr(
                        cpath,
                        format!("field '{col_key}' not found in type: '{col_type}'"),
                    ));
                };
                let col_value =
                    resolve_nested(ctx, col_value, &cfd.ty, cfd.default_value.is_some(), &cpath)?;
                if col_value.is_null() {
                    continue;
                }
                let dir = coerce_enum(ctx, col_value, "order_by", &cpath)?;
                let col = remote
                    .column_by_api_name(col_key)
                    .expect("aggregate order_by field must be a column");
                out.push(ir::OrderByItem {
                    target: ir::OrderTarget::ArrayRelAggregate {
                        path: chain.to_vec(),
                        remote_column: rel.remote_db_column.clone(),
                        remote_table: rel.remote_table.clone(),
                        op: op.to_string(),
                        column: Some(col.db_name.clone()),
                    },
                    direction: order_direction(&dir),
                });
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn order_direction_mapping() {
        assert_eq!(order_direction("asc"), ir::OrderDirection::Asc);
        assert_eq!(
            order_direction("asc_nulls_first"),
            ir::OrderDirection::AscNullsFirst
        );
        assert_eq!(
            order_direction("asc_nulls_last"),
            ir::OrderDirection::AscNullsLast
        );
        assert_eq!(order_direction("desc"), ir::OrderDirection::Desc);
        assert_eq!(
            order_direction("desc_nulls_first"),
            ir::OrderDirection::DescNullsFirst
        );
        assert_eq!(
            order_direction("desc_nulls_last"),
            ir::OrderDirection::DescNullsLast
        );
    }
}
