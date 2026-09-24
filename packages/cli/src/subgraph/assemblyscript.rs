//! A subgraph mapping, and the code `graph codegen` generates for it, is
//! AssemblyScript. Its syntax is TypeScript's, so it runs as JavaScript once the
//! types are gone — except where the same source means something else. Each of
//! those is rewritten here, before the file is imported:
//!
//! - `a / b` between two integers truncates. `timestamp / 86400` is a day bucket
//!   in a mapping and a fraction in JavaScript, and the fraction travels into
//!   ids and `Int` columns. Every `/` and `/=` goes through a runtime helper that
//!   truncates only when both operands are integers.
//! - `changetype<Foo>(x)` reinterprets a pointer. Nothing in JavaScript gives `x`
//!   the generated class's getters, so a class argument goes to a helper that
//!   sets the prototype.
//! - A `let` may redeclare a parameter: generated `try_` bindings do
//!   `let value = result.value` in a function taking `value`. JavaScript refuses
//!   it, so the local is renamed from its declaration on.
//! - Decorators are compiler hints (`@inline`), not runtime code.
//!
//! It fails loudly: a mapping that can't be rewritten can't be trusted to
//! compute what it computes under `asc`.

use std::{collections::HashSet, path::Path};

use anyhow::{anyhow, Result};
use oxc::{
    allocator::{Allocator, CloneIn, TakeIn, Vec as ArenaVec},
    ast::{ast::*, AstBuilder, NONE},
    ast_visit::{walk_mut, VisitMut},
    codegen::{Codegen, CodegenOptions},
    diagnostics::OxcDiagnostic,
    parser::Parser,
    semantic::SemanticBuilder,
    span::{SourceType, Span},
    syntax::{
        operator::{AssignmentOperator, BinaryOperator},
        scope::ScopeFlags,
    },
    transformer::{TransformOptions, Transformer},
};

pub const DIVIDE_HELPER: &str = "__envio_idiv";
pub const RETAG_HELPER: &str = "__envio_retag";

/// The JavaScript to run for one AssemblyScript file, with an inline source map
/// back to the original so a mapping's stack trace names its own lines.
pub fn to_javascript(source: &str, path: &Path) -> Result<String> {
    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, source, SourceType::ts()).parse();
    if parsed.panicked || !parsed.errors.is_empty() {
        return Err(describe(path, source, &parsed.errors));
    }
    let mut program = parsed.program;

    let mut rewrite = Rewrite {
        ast: AstBuilder::new(&allocator),
        classes: value_bindings(&program),
        renames: Vec::new(),
        refused: None,
    };
    rewrite.visit_program(&mut program);
    if let Some((span, message)) = rewrite.refused {
        return Err(anyhow!("{}: {message}", location(path, source, span)));
    }

    let scoping = SemanticBuilder::new()
        .build(&program)
        .semantic
        .into_scoping();
    let transformed = Transformer::new(&allocator, path, &TransformOptions::default())
        .build_with_scoping(scoping, &mut program);
    if !transformed.errors.is_empty() {
        return Err(describe(path, source, &transformed.errors));
    }

    let printed = Codegen::new()
        .with_options(CodegenOptions {
            source_map_path: Some(path.to_path_buf()),
            ..CodegenOptions::default()
        })
        .build(&program);
    let map = printed
        .map
        .map(|mut map| {
            map.set_source_contents(vec![Some(source)]);
            format!("//# sourceMappingURL={}\n", map.to_data_url())
        })
        .unwrap_or_default();
    Ok(format!("{}{map}", printed.code))
}

struct Rewrite<'a> {
    ast: AstBuilder<'a>,
    /// Names bound to a value at module level — classes and imports. Only these
    /// can be `changetype`'s target at runtime: `changetype<i32>` has no class.
    classes: HashSet<String>,
    /// Parameters a local has taken the name of, innermost last: the name, and
    /// what the local answers to instead.
    renames: Vec<(String, String)>,
    refused: Option<(Span, &'static str)>,
}

impl<'a> Rewrite<'a> {
    fn call(&self, span: Span, helper: &'static str, args: [Expression<'a>; 2]) -> Expression<'a> {
        let callee = self.ast.expression_identifier(span, helper);
        let args = self.ast.vec_from_iter(args.into_iter().map(Argument::from));
        self.ast.expression_call(span, callee, NONE, args, false)
    }

    /// The expression that reads what `target` assigns to, when reading it has
    /// no effect of its own: `a[i++] /= 2` would read `a[i++]` twice.
    fn read_of(&self, target: &AssignmentTarget<'a>) -> Option<Expression<'a>> {
        match target {
            AssignmentTarget::AssignmentTargetIdentifier(id) => {
                Some(self.ast.expression_identifier(id.span, id.name))
            }
            AssignmentTarget::StaticMemberExpression(member) if is_pure(&member.object) => Some(
                Expression::StaticMemberExpression(member.clone_in(self.ast.allocator)),
            ),
            _ => None,
        }
    }

    /// The class `changetype<Foo>` names, if it is one the runtime can reach.
    fn retag_target(&self, call: &CallExpression<'a>) -> Option<(Span, String)> {
        let Expression::Identifier(callee) = &call.callee else {
            return None;
        };
        if callee.name != "changetype" || call.arguments.len() != 1 {
            return None;
        }
        match call.type_arguments.as_ref()?.params.first()? {
            TSType::TSTypeReference(reference) => match &reference.type_name {
                TSTypeName::IdentifierReference(name)
                    if self.classes.contains(name.name.as_str()) =>
                {
                    Some((name.span, name.name.to_string()))
                }
                _ => None,
            },
            _ => None,
        }
    }
}

fn is_pure(expr: &Expression<'_>) -> bool {
    match expr {
        Expression::Identifier(_) | Expression::ThisExpression(_) => true,
        Expression::StaticMemberExpression(member) => is_pure(&member.object),
        _ => false,
    }
}

/// The lexical declarations `statement` makes under one of `params`' names.
fn shadowing(statement: &Statement<'_>, params: &[String]) -> Vec<String> {
    let Statement::VariableDeclaration(decl) = statement else {
        return Vec::new();
    };
    if !decl.kind.is_lexical() {
        return Vec::new();
    }
    decl.declarations
        .iter()
        .filter_map(|declarator| match &declarator.id {
            BindingPattern::BindingIdentifier(id)
                if params.iter().any(|param| id.name == param.as_str()) =>
            {
                Some(id.name.to_string())
            }
            _ => None,
        })
        .collect()
}

impl<'a> VisitMut<'a> for Rewrite<'a> {
    fn visit_expression(&mut self, expr: &mut Expression<'a>) {
        walk_mut::walk_expression(self, expr);
        match expr {
            Expression::BinaryExpression(binary) if binary.operator == BinaryOperator::Division => {
                let span = binary.span;
                let left = binary.left.take_in(self.ast.allocator);
                let right = binary.right.take_in(self.ast.allocator);
                *expr = self.call(span, DIVIDE_HELPER, [left, right]);
            }
            Expression::AssignmentExpression(assign)
                if assign.operator == AssignmentOperator::Division =>
            {
                let Some(read) = self.read_of(&assign.left) else {
                    self.refused.get_or_insert((
                        assign.span,
                        "Envio Subgraph can't divide into this target the way AssemblyScript \
                         does: an indexed or computed `/=` would evaluate its target twice. \
                         Divide into a local first.",
                    ));
                    return;
                };
                let right = assign.right.take_in(self.ast.allocator);
                assign.right = self.call(assign.span, DIVIDE_HELPER, [read, right]);
                assign.operator = AssignmentOperator::Assign;
            }
            Expression::CallExpression(call) => {
                let Some((class_span, class)) = self.retag_target(call) else {
                    return;
                };
                let span = call.span;
                let value = call.arguments[0]
                    .to_expression_mut()
                    .take_in(self.ast.allocator);
                let class = self
                    .ast
                    .expression_identifier(class_span, self.ast.ident(&class));
                *expr = self.call(span, RETAG_HELPER, [class, value]);
            }
            _ => {}
        }
    }

    fn visit_identifier_reference(&mut self, id: &mut IdentifierReference<'a>) {
        let renamed = self
            .renames
            .iter()
            .rev()
            .find(|(from, _)| id.name == from.as_str());
        if let Some((_, to)) = renamed {
            id.name = self.ast.ident(to);
        }
    }

    // A renamed local is renamed for the rest of its function, nested blocks
    // included; one of them declaring the name again would need block scoping
    // to tell the two apart, so it is refused rather than guessed at.
    fn visit_binding_identifier(&mut self, id: &mut BindingIdentifier<'a>) {
        if self
            .renames
            .iter()
            .any(|(from, _)| id.name == from.as_str())
        {
            self.refused.get_or_insert((
                id.span,
                "Envio Subgraph can't load this mapping: it declares a name that an \
                 earlier local in the same function already took over from a parameter. \
                 Rename one of them.",
            ));
        }
    }

    fn visit_function(&mut self, func: &mut Function<'a>, _flags: ScopeFlags) {
        let params: Vec<String> = func
            .params
            .items
            .iter()
            .filter_map(|param| match &param.pattern {
                BindingPattern::BindingIdentifier(id) => Some(id.name.to_string()),
                _ => None,
            })
            .collect();
        // A parameter hides any rename an enclosing function made of its name.
        let outer = std::mem::take(&mut self.renames);
        self.renames = outer
            .iter()
            .filter(|(from, _)| !params.contains(from))
            .cloned()
            .collect();

        self.visit_formal_parameters(&mut func.params);
        if let Some(body) = func.body.as_mut() {
            for statement in body.statements.iter_mut() {
                let taken = shadowing(statement, &params);
                // Its own initializer still reads the parameter, so a rename
                // starts once the declaring statement has been visited.
                self.visit_statement(statement);
                if let Statement::VariableDeclaration(decl) = statement {
                    for declarator in decl.declarations.iter_mut() {
                        if let BindingPattern::BindingIdentifier(id) = &mut declarator.id {
                            if taken.iter().any(|name| id.name == name.as_str()) {
                                let to = format!("{}__local", id.name);
                                self.renames.push((id.name.to_string(), to.clone()));
                                id.name = self.ast.ident(&to);
                            }
                        }
                    }
                }
            }
        }
        self.renames = outer;
    }

    fn visit_decorators(&mut self, decorators: &mut ArenaVec<'a, Decorator<'a>>) {
        decorators.clear();
    }
}

/// Module-level names a `changetype` target can refer to at runtime.
fn value_bindings(program: &Program<'_>) -> HashSet<String> {
    let mut names = HashSet::new();
    for statement in &program.body {
        let class = match statement {
            Statement::ClassDeclaration(class) => Some(class),
            Statement::ExportNamedDeclaration(export) => match &export.declaration {
                Some(Declaration::ClassDeclaration(class)) => Some(class),
                _ => None,
            },
            Statement::ImportDeclaration(import) if !import.import_kind.is_type() => {
                for specifier in import.specifiers.iter().flatten() {
                    names.insert(specifier.local().name.to_string());
                }
                None
            }
            _ => None,
        };
        if let Some(id) = class.and_then(|class| class.id.as_ref()) {
            names.insert(id.name.to_string());
        }
    }
    names
}

fn location(path: &Path, source: &str, span: Span) -> String {
    let offset = (span.start as usize).min(source.len());
    let before = &source[..offset];
    let line = before.matches('\n').count() + 1;
    let column = before[before.rfind('\n').map_or(0, |at| at + 1)..]
        .chars()
        .count()
        + 1;
    format!("{}:{line}:{column}", path.display())
}

fn describe(path: &Path, source: &str, diagnostics: &[OxcDiagnostic]) -> anyhow::Error {
    let rendered: Vec<String> = diagnostics
        .iter()
        .map(|diagnostic| {
            let span = diagnostic
                .labels
                .as_ref()
                .and_then(|labels| labels.first())
                .map(|label| Span::sized(label.offset() as u32, label.len() as u32))
                .unwrap_or_default();
            format!("{}: {}", location(path, source, span), diagnostic.message)
        })
        .collect();
    anyhow!(
        "Envio Subgraph couldn't read this mapping as AssemblyScript:\n  {}",
        rendered.join("\n  ")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn js(source: &str) -> String {
        let out = to_javascript(source, Path::new("src/mapping.ts")).expect("a readable mapping");
        out.split("//# sourceMappingURL=")
            .next()
            .unwrap()
            .to_string()
    }

    fn refusal(source: &str) -> String {
        to_javascript(source, Path::new("src/mapping.ts"))
            .expect_err("expected the mapping to be refused")
            .to_string()
    }

    #[test]
    fn divides_integers_through_the_helper() {
        assert_eq!(
            js("export function day(timestamp: i32, entity: Entity): i32 {
  let bucket = timestamp / (86400 / 2) / 2;
  bucket /= 2;
  entity.total /= 3;
  return bucket;
}"),
            "export function day(timestamp, entity) {
\tlet bucket = __envio_idiv(__envio_idiv(timestamp, __envio_idiv(86400, 2)), 2);
\tbucket = __envio_idiv(bucket, 2);
\tentity.total = __envio_idiv(entity.total, 3);
\treturn bucket;
}
"
        );
    }

    // Reading an indexed target twice could run its index twice, so this is
    // refused rather than rewritten into something the mapping didn't write.
    #[test]
    fn refuses_a_compound_division_into_a_computed_target() {
        assert_eq!(
            refusal("export function f(values: i32[], i: i32): void {\n  values[i++] /= 2;\n}"),
            "src/mapping.ts:2:3: Envio Subgraph can't divide into this target the way \
             AssemblyScript does: an indexed or computed `/=` would evaluate its target twice. \
             Divide into a local first."
        );
    }

    #[test]
    fn retags_changetype_onto_a_class_it_can_reach() {
        assert_eq!(
            js("import { Pair } from \"../generated/schema\";
export function f(value: Entity, n: i64): void {
  let pair = changetype<Pair>(value);
  let wide = changetype<i32>(n);
}"),
            "import { Pair } from \"../generated/schema\";
export function f(value, n) {
\tlet pair = __envio_retag(Pair, value);
\tlet wide = changetype(n);
}
"
        );
    }

    // What `graph codegen` emits for every call returning a value named like a
    // parameter — `try_transfer(to, value)` on any ERC-20.
    #[test]
    fn renames_a_local_that_redeclares_a_parameter() {
        assert_eq!(
            js("export class Token {
  try_transfer(to: Address, value: BigInt): CallResult<boolean> {
    let result = this.tryCall(\"transfer\", [to, value]);
    if (result.reverted) {
      return new CallResult();
    }
    let value = result.value;
    return CallResult.fromValue(value[0].toBoolean());
  }
}"),
            "export class Token {
\ttry_transfer(to, value) {
\t\tlet result = this.tryCall(\"transfer\", [to, value]);
\t\tif (result.reverted) {
\t\t\treturn new CallResult();
\t\t}
\t\tlet value__local = result.value;
\t\treturn CallResult.fromValue(value__local[0].toBoolean());
\t}
}
"
        );
    }

    #[test]
    fn refuses_a_block_that_redeclares_a_renamed_local() {
        assert_eq!(
            refusal(
                "function f(value: i32): i32 {
  let value = 1;
  if (value > 0) {
    let value = 2;
    return value;
  }
  return value;
}"
            ),
            "src/mapping.ts:4:9: Envio Subgraph can't load this mapping: it declares a name \
             that an earlier local in the same function already took over from a parameter. \
             Rename one of them."
        );
    }

    #[test]
    fn drops_decorators_and_types() {
        assert_eq!(
            js("import { BigInt } from \"@graphprotocol/graph-ts\";
export class Token {
  @inline
  scaled(amount: BigInt, decimals: u8): BigInt {
    return <BigInt>amount;
  }
}"),
            "export class Token {
\tscaled(amount, decimals) {
\t\treturn amount;
\t}
}
"
        );
    }

    #[test]
    fn locates_what_it_cannot_parse() {
        assert_eq!(
            refusal("export function f(): void {\n  let x = ;\n}"),
            "Envio Subgraph couldn't read this mapping as AssemblyScript:\n  \
             src/mapping.ts:2:11: Unexpected token"
        );
    }

    #[test]
    fn maps_the_output_back_to_the_mapping() {
        let out = to_javascript("export const a = 1 / 2;", Path::new("src/mapping.ts")).unwrap();
        assert!(
            out.ends_with("\n")
                && out
                    .lines()
                    .last()
                    .is_some_and(|line| line.starts_with("//# sourceMappingURL=data:")),
            "{out}"
        );
    }
}
