use super::{depth_error, q, verr, ASelSet, Ctx, GResult, MAX_DEPTH};
use std::collections::HashMap;

// ---------------------------------------------------------------------------
// Prepasses: fragment reachability, variable usage
// ---------------------------------------------------------------------------

fn english_list(names: &[&str]) -> String {
    match names.len() {
        0 => String::new(),
        1 => names[0].to_string(),
        _ => format!(
            "{} and {}",
            names[..names.len() - 1].join(", "),
            names[names.len() - 1]
        ),
    }
}

/// Checks fragment reachability (undefined spreads, cycles) and returns the
/// selection depth of `set` after fragment expansion, so the caller can
/// enforce the nesting limit on what the later walkers will actually
/// recurse into. `depths` memoizes each fully-visited fragment's expanded
/// depth: without it, a chain of fragments each spread twice re-descends
/// exponentially. `frames` counts live recursion (selection nesting plus
/// spread descents) and is capped so a long fragment chain cannot overflow
/// the stack before the expanded-depth check runs.
pub(super) fn fragment_prepass<'a>(
    ctx: &Ctx<'a>,
    set: &'a ASelSet,
    sel_path: &str,
    stack: &mut Vec<&'a str>,
    depths: &mut HashMap<&'a str, usize>,
    frames: usize,
) -> GResult<usize> {
    if frames > MAX_DEPTH {
        return Err(depth_error());
    }
    let mut depth = 0;
    for item in &set.items {
        match item {
            q::Selection::Field(f) => {
                let d = if !f.selection_set.items.is_empty() {
                    let inner = format!("{sel_path}.{}.selectionSet", f.name);
                    1 + fragment_prepass(ctx, &f.selection_set, &inner, stack, depths, frames + 1)?
                } else {
                    1
                };
                depth = depth.max(d);
            }
            q::Selection::FragmentSpread(spread) => {
                let name = spread.fragment_name.as_str();
                let Some(frag) = ctx.fragments.get(name) else {
                    return Err(verr(
                        sel_path,
                        format!("reference to undefined fragment \"{name}\""),
                    ));
                };
                let d = match depths.get(name) {
                    Some(&d) => d,
                    None => {
                        if let Some(first) = stack.iter().position(|n| *n == name) {
                            return Err(verr(
                                sel_path,
                                format!(
                                    "the fragment definition(s) {} form a cycle",
                                    english_list(&stack[first..])
                                ),
                            ));
                        }
                        stack.push(name);
                        let inner = format!("{sel_path}.{name}.selectionSet");
                        let d = fragment_prepass(
                            ctx,
                            &frag.selection_set,
                            &inner,
                            stack,
                            depths,
                            frames + 1,
                        )?;
                        stack.pop();
                        depths.insert(name, d);
                        d
                    }
                };
                depth = depth.max(d);
            }
            q::Selection::InlineFragment(inline) => {
                depth = depth.max(fragment_prepass(
                    ctx,
                    &inline.selection_set,
                    sel_path,
                    stack,
                    depths,
                    frames + 1,
                )?);
            }
        }
    }
    Ok(depth)
}
