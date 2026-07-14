use super::args::{api_to_db_column, expect_list, expect_object, resolve_item, resolve_nested};
use super::coerce::{coerce_bool_strict, coerce_column_value, coerce_enum, coerce_string_strict};
use super::{ir, model_table, verr, Column, Ctx, GResult, Scalar, TypeRef, V};

// ---------------------------------------------------------------------------
// bool_exp coercion
// ---------------------------------------------------------------------------

pub(super) fn coerce_bool_exp<'a>(
    ctx: &'a Ctx<'a>,
    table_name: &str,
    v: V<'a>,
    path: &str,
) -> GResult<ir::BoolExp> {
    let type_name = format!("{table_name}_bool_exp");
    let entries = expect_object(v, &type_name, path)?;
    let table = model_table(ctx, table_name);
    let type_def = ctx.registry.get(&type_name);

    let mut parts: Vec<ir::BoolExp> = Vec::new();
    for (key, value) in entries {
        let kpath = format!("{path}.{key}");
        let Some(fd) = type_def.and_then(|d| d.input_field(key)) else {
            return Err(verr(
                kpath,
                format!("field '{key}' not found in type: '{type_name}'"),
            ));
        };
        let value = resolve_nested(ctx, value, &fd.ty, fd.default_value.is_some(), &kpath)?;
        match key {
            "_and" | "_or" => {
                let items = expect_list(value, &kpath)?;
                let mut inner: Vec<ir::BoolExp> = Vec::new();
                for (i, item) in items.into_iter().enumerate() {
                    let ipath = format!("{kpath}[{i}]");
                    let elem_ty = TypeRef::non_null(TypeRef::named(&type_name));
                    let item = resolve_item(ctx, item, &elem_ty, &ipath)?;
                    inner.push(coerce_bool_exp(ctx, table_name, item, &ipath)?);
                }
                parts.push(if key == "_and" {
                    ir::BoolExp::And(inner)
                } else {
                    ir::BoolExp::Or(inner)
                });
            }
            "_not" => {
                let inner = coerce_bool_exp(ctx, table_name, value, &kpath)?;
                parts.push(ir::BoolExp::Not(Box::new(inner)));
            }
            _ => {
                if let Some(col) = table.column_by_api_name(key) {
                    let ops = coerce_comparison(ctx, col, value, &kpath)?;
                    for op in ops {
                        parts.push(ir::BoolExp::Compare {
                            column: col.db_name.clone(),
                            scalar: col.scalar,
                            pg_type: col.pg_type.clone(),
                            is_array: col.is_array,
                            op,
                        });
                    }
                } else if let Some(rel) = table.object_relationships.iter().find(|r| r.name == key)
                {
                    let inner = coerce_bool_exp(ctx, &rel.remote_table, value, &kpath)?;
                    parts.push(ir::BoolExp::ObjectRel {
                        local_column: rel.local_db_column.clone(),
                        remote_table: rel.remote_table.clone(),
                        exp: Box::new(inner),
                    });
                } else if let Some(rel) = table.array_relationships.iter().find(|r| r.name == key) {
                    let inner = coerce_bool_exp(ctx, &rel.remote_table, value, &kpath)?;
                    parts.push(ir::BoolExp::ArrayRel {
                        remote_column: rel.remote_db_column.clone(),
                        remote_table: rel.remote_table.clone(),
                        exp: Box::new(inner),
                    });
                } else if let Some(rel) = key
                    .strip_suffix("_aggregate")
                    .and_then(|base| table.array_relationships.iter().find(|r| r.name == base))
                {
                    let preds = coerce_aggregate_bool_exp(ctx, rel, value, &kpath)?;
                    parts.extend(preds);
                } else {
                    return Err(verr(
                        kpath,
                        format!("field '{key}' not found in type: '{type_name}'"),
                    ));
                }
            }
        }
    }
    Ok(if parts.len() == 1 {
        parts.pop().unwrap()
    } else {
        ir::BoolExp::And(parts)
    })
}

// ---------------------------------------------------------------------------
// Comparison expressions
// ---------------------------------------------------------------------------

fn comparison_type_name(scalar: Scalar, pg_type: &str, is_array: bool) -> String {
    let s = scalar.gql_name(pg_type);
    if is_array {
        format!("{s}_array_comparison_exp")
    } else {
        format!("{s}_comparison_exp")
    }
}

#[derive(Clone, Copy)]
struct ComparisonColumn<'a> {
    scalar: Scalar,
    pg_type: &'a str,
    pg_type_schema: &'a str,
    is_array: bool,
}

fn coerce_comparison<'a>(
    ctx: &'a Ctx<'a>,
    col: &Column,
    v: V<'a>,
    path: &str,
) -> GResult<Vec<ir::CompareOp>> {
    let type_name = comparison_type_name(col.scalar, &col.pg_type, col.is_array);
    coerce_comparison_ops(
        ctx,
        ComparisonColumn {
            scalar: col.scalar,
            pg_type: &col.pg_type,
            pg_type_schema: &col.pg_type_schema,
            is_array: col.is_array,
        },
        &type_name,
        v,
        path,
    )
}

fn coerce_comparison_ops<'a>(
    ctx: &'a Ctx<'a>,
    column: ComparisonColumn<'_>,
    type_name: &str,
    v: V<'a>,
    path: &str,
) -> GResult<Vec<ir::CompareOp>> {
    let entries = expect_object(v, type_name, path)?;
    let type_def = ctx.registry.get(type_name);

    let mut ops: Vec<ir::CompareOp> = Vec::new();
    for (op, value) in entries {
        let opath = format!("{path}.{op}");
        // The registry defines exactly which operators exist per scalar;
        // when the comparison type itself is absent (e.g. Int predicates
        // with no int column anywhere), fall back to accepting the op.
        if let Some(def) = type_def {
            if def.input_field(op).is_none() {
                return Err(verr(
                    opath,
                    format!("field '{op}' not found in type: '{type_name}'"),
                ));
            }
        }
        let loc = type_def.and_then(|d| d.input_field(op));
        let value = match loc {
            Some(fd) => resolve_nested(ctx, value, &fd.ty, fd.default_value.is_some(), &opath)?,
            None => value,
        };
        let scalar_value = |v: V<'a>, p: &str| {
            coerce_column_value(
                ctx,
                column.scalar,
                column.pg_type,
                column.pg_type_schema,
                column.is_array,
                v,
                p,
            )
        };
        let list_value = |v: V<'a>, p: &str| -> GResult<Vec<ir::SqlValue>> {
            let items = expect_list(v, p)?;
            let mut out = Vec::new();
            for (i, item) in items.into_iter().enumerate() {
                out.push(scalar_value(item, &format!("{p}[{i}]"))?);
            }
            Ok(out)
        };
        let compare = match op {
            "_eq" => ir::CompareOp::Eq(scalar_value(value, &opath)?),
            "_neq" => ir::CompareOp::Neq(scalar_value(value, &opath)?),
            "_gt" => ir::CompareOp::Gt(scalar_value(value, &opath)?),
            "_gte" => ir::CompareOp::Gte(scalar_value(value, &opath)?),
            "_lt" => ir::CompareOp::Lt(scalar_value(value, &opath)?),
            "_lte" => ir::CompareOp::Lte(scalar_value(value, &opath)?),
            "_in" => ir::CompareOp::In(list_value(value, &opath)?),
            "_nin" => ir::CompareOp::Nin(list_value(value, &opath)?),
            "_is_null" => ir::CompareOp::IsNull(coerce_bool_strict(value, &opath)?),
            "_like" => ir::CompareOp::Like(scalar_value(value, &opath)?),
            "_nlike" => ir::CompareOp::Nlike(scalar_value(value, &opath)?),
            "_ilike" => ir::CompareOp::Ilike(scalar_value(value, &opath)?),
            "_nilike" => ir::CompareOp::Nilike(scalar_value(value, &opath)?),
            "_similar" => ir::CompareOp::Similar(scalar_value(value, &opath)?),
            "_nsimilar" => ir::CompareOp::Nsimilar(scalar_value(value, &opath)?),
            "_regex" => ir::CompareOp::Regex(scalar_value(value, &opath)?),
            "_iregex" => ir::CompareOp::Iregex(scalar_value(value, &opath)?),
            "_nregex" => ir::CompareOp::Nregex(scalar_value(value, &opath)?),
            "_niregex" => ir::CompareOp::Niregex(scalar_value(value, &opath)?),
            "_contains" => ir::CompareOp::Contains(scalar_value(value, &opath)?),
            "_contained_in" => ir::CompareOp::ContainedIn(scalar_value(value, &opath)?),
            "_has_key" => {
                let s = coerce_string_strict(value, &opath)?;
                ir::CompareOp::HasKey(ir::SqlValue::new(s, "text"))
            }
            "_has_keys_all" | "_has_keys_any" => {
                let items = expect_list(value, &opath)?;
                let mut out = Vec::new();
                for (i, item) in items.into_iter().enumerate() {
                    let s = coerce_string_strict(item, &format!("{opath}[{i}]"))?;
                    out.push(ir::SqlValue::new(s, "text"));
                }
                if op == "_has_keys_all" {
                    ir::CompareOp::HasKeysAll(out)
                } else {
                    ir::CompareOp::HasKeysAny(out)
                }
            }
            "_cast" => {
                let cast_entries = expect_object(value, "jsonb_cast_exp", &opath)?;
                let mut inner: Vec<ir::CompareOp> = Vec::new();
                for (ck, cv) in cast_entries {
                    let cpath = format!("{opath}.{ck}");
                    if ck != "String" {
                        return Err(verr(
                            cpath,
                            format!("field '{ck}' not found in type: 'jsonb_cast_exp'"),
                        ));
                    }
                    let text_ops = coerce_comparison_ops(
                        ctx,
                        ComparisonColumn {
                            scalar: Scalar::String,
                            pg_type: "text",
                            pg_type_schema: "pg_catalog",
                            is_array: false,
                        },
                        "String_comparison_exp",
                        cv,
                        &cpath,
                    )?;
                    inner.extend(text_ops);
                }
                ir::CompareOp::CastText(inner)
            }
            other => {
                return Err(verr(
                    opath,
                    format!("field '{other}' not found in type: '{type_name}'"),
                ));
            }
        };
        ops.push(compare);
    }
    Ok(ops)
}

// ---------------------------------------------------------------------------
// Aggregate predicates in bool_exp
// ---------------------------------------------------------------------------

fn coerce_aggregate_bool_exp<'a>(
    ctx: &'a Ctx<'a>,
    rel: &crate::serve::model::ArrayRelationship,
    v: V<'a>,
    path: &str,
) -> GResult<Vec<ir::BoolExp>> {
    let rt = &rel.remote_table;
    let type_name = format!("{rt}_aggregate_bool_exp");
    let type_def = ctx.registry.get(&type_name);
    let remote = model_table(ctx, rt);

    let mut out: Vec<ir::BoolExp> = Vec::new();
    for (op, value) in expect_object(v, &type_name, path)? {
        let opath = format!("{path}.{op}");
        let Some(fd) = type_def.and_then(|d| d.input_field(op)) else {
            return Err(verr(
                opath,
                format!("field '{op}' not found in type: '{type_name}'"),
            ));
        };
        let value = resolve_nested(ctx, value, &fd.ty, fd.default_value.is_some(), &opath)?;
        let inner_type = format!("{rt}_aggregate_bool_exp_{op}");
        let inner_def = ctx.registry.get(&inner_type);
        let entries = expect_object(value, &inner_type, &opath)?;

        let mut columns: Vec<String> = Vec::new();
        let mut distinct = false;
        let mut filter: Option<Box<ir::BoolExp>> = None;
        let mut predicate: Option<Vec<ir::CompareOp>> = None;
        let mut has_arguments = false;
        for (key, kv) in entries {
            let kpath = format!("{opath}.{key}");
            let Some(kfd) = inner_def.and_then(|d| d.input_field(key)) else {
                return Err(verr(
                    kpath,
                    format!("field '{key}' not found in type: '{inner_type}'"),
                ));
            };
            let kv = resolve_nested(ctx, kv, &kfd.ty, kfd.default_value.is_some(), &kpath)?;
            match key {
                "arguments" => {
                    has_arguments = true;
                    if op == "count" {
                        // Omitting `arguments` entirely means count(*) (the
                        // loop body above never runs, so `columns` stays
                        // empty); an explicit `null` is still a validation
                        // error, matching Hasura's "expected a list, but
                        // found null" for the analogous by-pk/eq cases.
                        let enum_name = format!("{rt}_select_column");
                        for (i, item) in expect_list(kv, &kpath)?.into_iter().enumerate() {
                            let ipath = format!("{kpath}[{i}]");
                            let api = coerce_enum(ctx, item, &enum_name, &ipath)?;
                            columns.push(api_to_db_column(remote, &api));
                        }
                    } else {
                        // Non-count ops (bool_and/bool_or) require a single
                        // non-null column enum; let coerce_enum reject a null
                        // literal instead of silently emitting `op(*)`.
                        let enum_name = format!(
                            "{rt}_select_column_{rt}_aggregate_bool_exp_{op}_arguments_columns"
                        );
                        let api = coerce_enum(ctx, kv, &enum_name, &kpath)?;
                        columns.push(api_to_db_column(remote, &api));
                    }
                }
                "distinct" => {
                    distinct = coerce_bool_strict(kv, &kpath)?;
                }
                "filter" => {
                    if !kv.is_null() {
                        filter = Some(Box::new(coerce_bool_exp(ctx, rt, kv, &kpath)?));
                    }
                }
                "predicate" => {
                    let (scalar, pg, cmp) = if op == "count" {
                        (Scalar::Int, "int4", "Int_comparison_exp")
                    } else {
                        (Scalar::Boolean, "bool", "Boolean_comparison_exp")
                    };
                    predicate = Some(coerce_comparison_ops(
                        ctx,
                        ComparisonColumn {
                            scalar,
                            pg_type: pg,
                            pg_type_schema: "pg_catalog",
                            is_array: false,
                        },
                        cmp,
                        kv,
                        &kpath,
                    )?);
                }
                _ => {}
            }
        }
        let Some(predicate) = predicate else {
            return Err(verr(
                format!("{opath}.predicate"),
                "missing required field 'predicate'",
            ));
        };
        if op != "count" && !has_arguments {
            return Err(verr(
                format!("{opath}.arguments"),
                "missing required field 'arguments'",
            ));
        }
        out.push(ir::BoolExp::ArrayRelAggregate {
            remote_column: rel.remote_db_column.clone(),
            remote_table: rt.clone(),
            pred: ir::AggregatePredicate {
                op: op.to_string(),
                columns,
                distinct,
                filter,
                predicate,
            },
        });
    }
    Ok(out)
}
