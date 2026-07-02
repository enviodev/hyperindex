use super::{q, verr, ASelSet, Ctx, GResult};

// ---------------------------------------------------------------------------
// Prepasses: fragment reachability, variable usage
// ---------------------------------------------------------------------------

fn english_list(names: &[String]) -> String {
    match names.len() {
        0 => String::new(),
        1 => names[0].clone(),
        _ => format!(
            "{} and {}",
            names[..names.len() - 1].join(", "),
            names[names.len() - 1]
        ),
    }
}

pub(super) fn fragment_prepass(
    ctx: &Ctx,
    set: &ASelSet,
    sel_path: &str,
    stack: &mut Vec<String>,
) -> GResult<()> {
    for item in &set.items {
        match item {
            q::Selection::Field(f) => {
                if !f.selection_set.items.is_empty() {
                    let inner = format!("{sel_path}.{}.selectionSet", f.name);
                    fragment_prepass(ctx, &f.selection_set, &inner, stack)?;
                }
            }
            q::Selection::FragmentSpread(spread) => {
                let name = spread.fragment_name.as_str();
                let Some(frag) = ctx.fragments.get(name) else {
                    return Err(verr(
                        sel_path,
                        format!("reference to undefined fragment \"{name}\""),
                    ));
                };
                if let Some(first) = stack.iter().position(|n| n == name) {
                    return Err(verr(
                        sel_path,
                        format!(
                            "the fragment definition(s) {} form a cycle",
                            english_list(&stack[first..])
                        ),
                    ));
                }
                stack.push(name.to_string());
                let inner = format!("{sel_path}.{name}.selectionSet");
                fragment_prepass(ctx, &frag.selection_set, &inner, stack)?;
                stack.pop();
            }
            q::Selection::InlineFragment(inline) => {
                fragment_prepass(ctx, &inline.selection_set, sel_path, stack)?;
            }
        }
    }
    Ok(())
}
