use super::{
    perr, q, verr, ADirective, ASelSet, AType, AValue, AVarDef, Ctx, GResult, Json, NULL_LIT,
};
use std::collections::HashMap;

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

pub(super) enum VarValue<'a> {
    Json(&'a Json),
    Lit(&'a AValue),
}

pub(super) struct VarInfo<'a> {
    pub(super) ty: &'a AType,
    pub(super) default: Option<&'a AValue>,
    pub(super) value: VarValue<'a>,
}

pub(super) fn atype_display(t: &AType) -> String {
    match t {
        q::Type::NamedType(n) => n.clone(),
        q::Type::ListType(inner) => format!("[{}]", atype_display(inner)),
        q::Type::NonNullType(inner) => format!("{}!", atype_display(inner)),
    }
}

pub(super) fn atype_is_non_null(t: &AType) -> bool {
    matches!(t, q::Type::NonNullType(_))
}

pub(super) fn build_variables<'a>(
    defs: &'a [AVarDef],
    provided: Option<&'a serde_json::Map<String, Json>>,
) -> GResult<HashMap<&'a str, VarInfo<'a>>> {
    let mut vars: HashMap<&str, VarInfo> = HashMap::new();
    for def in defs {
        if vars.contains_key(def.name.as_str()) {
            return Err(perr(
                "$",
                format!("multiple definitions for variable \"{}\"", def.name),
            ));
        }
        let value = match provided.and_then(|m| m.get(def.name.as_str())) {
            Some(json) => {
                if json.is_null() && atype_is_non_null(&def.var_type) {
                    return Err(verr(
                        "$",
                        format!(
                            "null value found for non-nullable type: \"{}\"",
                            atype_display(&def.var_type)
                        ),
                    ));
                }
                VarValue::Json(json)
            }
            None => match &def.default_value {
                Some(d) => VarValue::Lit(d),
                None => {
                    if atype_is_non_null(&def.var_type) {
                        return Err(verr(
                            "$",
                            format!(
                                "expecting a value for non-nullable variable: \"{}\"",
                                def.name
                            ),
                        ));
                    }
                    VarValue::Lit(&NULL_LIT)
                }
            },
        };
        vars.insert(
            def.name.as_str(),
            VarInfo {
                ty: &def.var_type,
                default: def.default_value.as_ref(),
                value,
            },
        );
    }
    Ok(vars)
}

pub(super) fn variable_prepass(ctx: &Ctx, set: &ASelSet) -> GResult<()> {
    fn mark_value(ctx: &Ctx, v: &AValue) -> GResult<()> {
        match v {
            q::Value::Variable(name) => {
                if !ctx.vars.contains_key(name.as_str()) {
                    return Err(verr("$", format!("unbound variable \"{name}\"")));
                }
                ctx.mark_used(name);
            }
            q::Value::List(items) => {
                for item in items {
                    mark_value(ctx, item)?;
                }
            }
            q::Value::Object(map) => {
                for value in map.values() {
                    mark_value(ctx, value)?;
                }
            }
            _ => {}
        }
        Ok(())
    }
    fn mark_directives(ctx: &Ctx, dirs: &[ADirective]) -> GResult<()> {
        for d in dirs {
            for (_, v) in &d.arguments {
                mark_value(ctx, v)?;
            }
        }
        Ok(())
    }
    for item in &set.items {
        match item {
            q::Selection::Field(f) => {
                for (_, v) in &f.arguments {
                    mark_value(ctx, v)?;
                }
                mark_directives(ctx, &f.directives)?;
                variable_prepass(ctx, &f.selection_set)?;
            }
            q::Selection::FragmentSpread(spread) => {
                mark_directives(ctx, &spread.directives)?;
                if let Some(frag) = ctx.fragments.get(spread.fragment_name.as_str()) {
                    variable_prepass(ctx, &frag.selection_set)?;
                }
            }
            q::Selection::InlineFragment(inline) => {
                mark_directives(ctx, &inline.directives)?;
                variable_prepass(ctx, &inline.selection_set)?;
            }
        }
    }
    Ok(())
}
