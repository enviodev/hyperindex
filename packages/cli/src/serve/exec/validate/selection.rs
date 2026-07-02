use super::coerce::coerce_bool_strict;
use super::{q, verr, ADirective, ASelSet, AValue, Ctx, GResult, TypeRef};
use std::collections::{BTreeMap, HashMap};

// ---------------------------------------------------------------------------
// Selection walking: directives, fragments, field merging
// ---------------------------------------------------------------------------

pub(super) struct Flat<'a> {
    pub(super) key: String,
    pub(super) name: &'a str,
    pub(super) args: &'a [(String, AValue)],
    pub(super) sel_sets: Vec<&'a ASelSet>,
    pub(super) had_selection: bool,
}

/// Evaluates @include/@skip (with variables) on a selection item. Returns
/// false when the item must be dropped. Unknown/duplicate directives and
/// bad `if` arguments error with paths anchored at the enclosing
/// selection set, matching Hasura.
fn eval_directives<'a>(ctx: &'a Ctx<'a>, dirs: &'a [ADirective], sel_path: &str) -> GResult<bool> {
    if dirs.is_empty() {
        return Ok(true);
    }
    let mut seen: Vec<&str> = Vec::new();
    let mut dups: Vec<&str> = Vec::new();
    for d in dirs {
        let name = d.name.as_str();
        if seen.contains(&name) {
            if !dups.contains(&name) {
                dups.push(name);
            }
        } else {
            seen.push(name);
        }
    }
    if !dups.is_empty() {
        let list = dups
            .iter()
            .map(|n| format!("'{n}'"))
            .collect::<Vec<_>>()
            .join(", ");
        return Err(verr(
            sel_path,
            format!("the following directives are used more than once: [{list}]"),
        ));
    }

    let mut include = true;
    for d in dirs {
        let name = d.name.as_str();
        match name {
            "include" | "skip" => {
                for (arg, _) in &d.arguments {
                    if arg != "if" {
                        return Err(verr(
                            format!("{sel_path}.{name}"),
                            format!("'{name}' has no argument named '{arg}'"),
                        ));
                    }
                }
                let if_path = format!("{sel_path}.{name}.args.if");
                let Some((_, raw)) = d.arguments.iter().find(|(a, _)| a == "if") else {
                    return Err(verr(if_path, "missing required field 'if'"));
                };
                let loc_ty = TypeRef::non_null(TypeRef::named("Boolean"));
                let v = ctx.resolve(raw, &loc_ty, false, &if_path)?;
                let cond = coerce_bool_strict(v, &if_path)?;
                match name {
                    "include" if !cond => include = false,
                    "skip" if cond => include = false,
                    _ => {}
                }
            }
            "cached" => {
                return Err(verr(
                    sel_path,
                    "directive 'cached' is not allowed on a field",
                ));
            }
            other => {
                return Err(verr(
                    sel_path,
                    format!("directive '{other}' is not defined in the schema"),
                ));
            }
        }
    }
    Ok(include)
}

pub(super) fn collect_fields<'a>(
    ctx: &'a Ctx<'a>,
    type_name: &str,
    sets: &[&'a ASelSet],
    sel_path: &str,
) -> GResult<Vec<Flat<'a>>> {
    let mut out: Vec<Flat<'a>> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();
    for set in sets {
        collect_into(ctx, type_name, set, sel_path, &mut out, &mut index)?;
    }
    Ok(out)
}

fn collect_into<'a>(
    ctx: &'a Ctx<'a>,
    type_name: &str,
    set: &'a ASelSet,
    sel_path: &str,
    out: &mut Vec<Flat<'a>>,
    index: &mut HashMap<String, usize>,
) -> GResult<()> {
    for item in &set.items {
        match item {
            q::Selection::Field(f) => {
                if !eval_directives(ctx, &f.directives, sel_path)? {
                    continue;
                }
                let key = f.alias.clone().unwrap_or_else(|| f.name.clone());
                match index.get(&key) {
                    Some(&i) => {
                        let existing = &mut out[i];
                        if existing.name != f.name {
                            return Err(verr(
                                sel_path,
                                format!(
                                    "selection of both '{}' and '{}' specify the same response name, '{}'",
                                    existing.name, f.name, key
                                ),
                            ));
                        }
                        if !args_equal(existing.args, &f.arguments) {
                            return Err(verr(
                                sel_path,
                                format!(
                                    "inconsistent arguments between multiple selections of field '{}'",
                                    f.name
                                ),
                            ));
                        }
                        if !f.selection_set.items.is_empty() {
                            existing.sel_sets.push(&f.selection_set);
                            existing.had_selection = true;
                        }
                    }
                    None => {
                        index.insert(key.clone(), out.len());
                        let had_selection = !f.selection_set.items.is_empty();
                        out.push(Flat {
                            key,
                            name: &f.name,
                            args: &f.arguments,
                            sel_sets: if had_selection {
                                vec![&f.selection_set]
                            } else {
                                vec![]
                            },
                            had_selection,
                        });
                    }
                }
            }
            q::Selection::FragmentSpread(spread) => {
                if !eval_directives(ctx, &spread.directives, sel_path)? {
                    continue;
                }
                let Some(frag) = ctx.fragments.get(spread.fragment_name.as_str()) else {
                    return Err(verr(
                        sel_path,
                        format!(
                            "reference to undefined fragment \"{}\"",
                            spread.fragment_name
                        ),
                    ));
                };
                // Non-matching (or unknown) type conditions drop the
                // fragment silently, as Hasura does.
                let q::TypeCondition::On(cond) = &frag.type_condition;
                if cond == type_name {
                    collect_into(ctx, type_name, &frag.selection_set, sel_path, out, index)?;
                }
            }
            q::Selection::InlineFragment(inline) => {
                if !eval_directives(ctx, &inline.directives, sel_path)? {
                    continue;
                }
                let matches = match &inline.type_condition {
                    None => true,
                    Some(q::TypeCondition::On(cond)) => cond == type_name,
                };
                if matches {
                    collect_into(ctx, type_name, &inline.selection_set, sel_path, out, index)?;
                }
            }
        }
    }
    Ok(())
}

fn args_equal(a: &[(String, AValue)], b: &[(String, AValue)]) -> bool {
    let to_map =
        |args: &[(String, AValue)]| -> BTreeMap<String, AValue> { args.iter().cloned().collect() };
    to_map(a) == to_map(b)
}
