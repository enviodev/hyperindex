//! A subgraph mapping, and the code `graph codegen` generates for it, is
//! AssemblyScript. Its syntax is TypeScript's, so it runs as JavaScript once the
//! types are gone — except where the same source means something else. Each of
//! those is rewritten here, before the file is imported:
//!
//! - Operators. graph-ts overloads arithmetic and comparison on `BigInt`,
//!   `BigDecimal` and `ByteArray`, and AssemblyScript calls the overload, where
//!   JavaScript would coerce or compare identity — `address == ZERO_ADDRESS`
//!   would never hold. And `a / b` between two integers truncates:
//!   `timestamp / 86400` is a day bucket in a mapping and a fraction in
//!   JavaScript. Every such operator, compound assignment included, goes through
//!   a runtime helper that calls the overload when there is one and otherwise
//!   computes what AssemblyScript does.
//! - `changetype<Foo>(x)` reinterprets a pointer. Nothing in JavaScript gives `x`
//!   the generated class's getters, so a class argument goes to a helper that
//!   sets the prototype.
//! - A `let` may redeclare a parameter: generated `try_` bindings do
//!   `let value = result.value` in a function taking `value`. JavaScript refuses
//!   it of `let` and allows it of `var`, which reads the parameter until the
//!   declaration and the local after it — as AssemblyScript does, having no
//!   closures to tell the two bindings apart.
//! - Decorators are compiler hints (`@inline`), not runtime code.
//!
//! It fails loudly: a mapping that can't be rewritten can't be trusted to
//! compute what it computes under `asc`.

use std::{collections::HashSet, path::Path};

use anyhow::{anyhow, Result};
use oxc::{
    allocator::{Allocator, CloneIn, GetAllocator, TakeIn, Vec as ArenaVec},
    ast::{ast::*, builder::AstBuilder},
    ast_visit::{walk_mut, VisitMut},
    codegen::{Codegen, CodegenOptions},
    diagnostics::OxcDiagnostic,
    parser::Parser,
    semantic::SemanticBuilder,
    span::{SourceType, Span},
    syntax::{
        operator::{AssignmentOperator, BinaryOperator, UnaryOperator},
        scope::ScopeFlags,
    },
    transformer::{TransformOptions, Transformer},
};

pub const OPERATORS_HELPER: &str = "__envio_op";
pub const RETAG_HELPER: &str = "__envio_retag";
pub const EVENT_CLASSES_EXPORT: &str = "__envio_event_classes";

/// `export function handleTransfer(event: Transfer)` names, in a type, the
/// generated class graph-node would hand it — the class whose `params` getters
/// codegen wrote. Types don't survive into JavaScript, so each exported
/// function's first-parameter class is also exported as a value, keyed by the
/// function's name, for the runtime to build the event as that class.
fn event_classes_export(program: &Program<'_>, classes: &HashSet<String>) -> Option<String> {
    let entries: Vec<String> = program
        .body
        .iter()
        .filter_map(|statement| match statement {
            Statement::ExportDeclaration(export) => match &export.declaration {
                Declaration::FunctionDeclaration(func) => Some(func),
                _ => None,
            },
            _ => None,
        })
        .filter_map(|func| {
            let name = func.id.as_ref()?.name;
            let annotation = func.params.items.first()?.type_annotation.as_ref()?;
            let class = class_ref(&annotation.type_annotation, classes)?;
            Some(format!("{name}: {}", class.name))
        })
        .collect();
    (!entries.is_empty()).then(|| {
        format!(
            "export const {EVENT_CLASSES_EXPORT} = {{ {} }};",
            entries.join(", ")
        )
    })
}

/// The class a type names, when it is one of `classes`.
fn class_ref<'b>(
    ty: &'b TSType<'_>,
    classes: &HashSet<String>,
) -> Option<&'b IdentifierReference<'b>> {
    let TSType::TSTypeReference(reference) = ty else {
        return None;
    };
    match &reference.type_name {
        TSTypeName::IdentifierReference(class) if classes.contains(class.name.as_str()) => {
            Some(class)
        }
        _ => None,
    }
}

/// The JavaScript to run for one AssemblyScript file, with an inline source map
/// back to the original so a mapping's stack trace names its own lines.
pub fn to_javascript(source: &str, path: &Path) -> Result<String> {
    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, source, SourceType::ts()).parse();
    if parsed.panicked || parsed.diagnostics.has_errors() {
        return Err(describe(path, source, parsed.diagnostics.errors()));
    }
    let mut program = parsed.program;

    let mut rewrite = Rewrite {
        ast: AstBuilder::new(&allocator),
        classes: value_bindings(&program),
        refused: None,
    };
    rewrite.visit_program(&mut program);
    if let Some((span, message)) = rewrite.refused {
        return Err(anyhow!("{}: {message}", location(path, source, span)));
    }
    if let Some(export) = event_classes_export(&program, &rewrite.classes) {
        let export = allocator.alloc_str(&export);
        let appended = Parser::new(&allocator, export, SourceType::ts()).parse();
        program.body.extend(appended.program.body);
    }

    let scoping = SemanticBuilder::new()
        .build(&program)
        .semantic
        .into_scoping();
    let transformed = Transformer::new(&allocator, path, &TransformOptions::default())
        .build_with_scoping(scoping, &mut program);
    if transformed.diagnostics.has_errors() {
        return Err(describe(path, source, transformed.diagnostics.errors()));
    }

    let printed = Codegen::new()
        .with_options(CodegenOptions {
            source_map_path: Some(path.to_path_buf()),
            ..CodegenOptions::default()
        })
        .build(&program);
    let map = printed
        .map
        // Mappings only: the source is on disk, and embedding it would double
        // every generated binding's size for the stack traces that use the map.
        .map(|map| format!("//# sourceMappingURL={}\n", map.to_data_url()))
        .unwrap_or_default();
    Ok(format!("{}{map}", printed.code))
}

struct Rewrite<'a> {
    ast: AstBuilder<'a>,
    /// Names bound to a value at module level — classes and imports. Only these
    /// can be `changetype`'s target at runtime: `changetype<i32>` has no class.
    classes: HashSet<String>,
    refused: Option<(Span, &'static str)>,
}

/// The `OPERATORS_HELPER` method standing in for a binary operator.
fn binary_helper(operator: BinaryOperator) -> Option<&'static str> {
    Some(match operator {
        BinaryOperator::Addition => "add",
        BinaryOperator::Subtraction => "sub",
        BinaryOperator::Multiplication => "mul",
        BinaryOperator::Division => "div",
        BinaryOperator::Remainder => "rem",
        BinaryOperator::Equality => "eq",
        BinaryOperator::Inequality => "ne",
        BinaryOperator::LessThan => "lt",
        BinaryOperator::LessEqualThan => "le",
        BinaryOperator::GreaterThan => "gt",
        BinaryOperator::GreaterEqualThan => "ge",
        _ => return None,
    })
}

fn assignment_helper(operator: AssignmentOperator) -> Option<&'static str> {
    Some(match operator {
        AssignmentOperator::Addition => "add",
        AssignmentOperator::Subtraction => "sub",
        AssignmentOperator::Multiplication => "mul",
        AssignmentOperator::Division => "div",
        AssignmentOperator::Remainder => "rem",
        _ => return None,
    })
}

impl<'a> Rewrite<'a> {
    fn call<const N: usize>(
        &self,
        span: Span,
        helper: &'static str,
        args: [Expression<'a>; N],
    ) -> Expression<'a> {
        let callee = Expression::new_identifier(span, helper, &self.ast);
        let args = ArenaVec::from_iter_in(args.into_iter().map(Argument::from), &self.ast);
        Expression::new_call_expression(span, callee, None, args, false, &self.ast)
    }

    /// `OPERATORS_HELPER.method(args)`.
    fn operator<const N: usize>(
        &self,
        span: Span,
        method: &'static str,
        args: [Expression<'a>; N],
    ) -> Expression<'a> {
        let object = Expression::new_identifier(span, OPERATORS_HELPER, &self.ast);
        let property = IdentifierName::new(span, method, &self.ast);
        let callee =
            Expression::new_static_member_expression(span, object, property, false, &self.ast);
        let args = ArenaVec::from_iter_in(args.into_iter().map(Argument::from), &self.ast);
        Expression::new_call_expression(span, callee, None, args, false, &self.ast)
    }

    /// The expression that reads what `target` assigns to, when reading it has
    /// no effect of its own: `a[i++] /= 2` would read `a[i++]` twice.
    fn read_of(&self, target: &AssignmentTarget<'a>) -> Option<Expression<'a>> {
        match target {
            AssignmentTarget::AssignmentTargetIdentifier(id) => {
                Some(Expression::new_identifier(id.span, id.name, &self.ast))
            }
            AssignmentTarget::StaticMemberExpression(member) if is_pure(&member.object) => Some(
                Expression::StaticMemberExpression(member.clone_in(self.ast.allocator())),
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
        let class = class_ref(call.type_arguments.as_ref()?.params.first()?, &self.classes)?;
        Some((class.span, class.name.to_string()))
    }
}

fn is_pure(expr: &Expression<'_>) -> bool {
    match expr {
        Expression::Identifier(_) | Expression::ThisExpression(_) => true,
        Expression::StaticMemberExpression(member) => is_pure(&member.object),
        _ => false,
    }
}

impl<'a> VisitMut<'a> for Rewrite<'a> {
    fn visit_expression(&mut self, expr: &mut Expression<'a>) {
        walk_mut::walk_expression(self, expr);
        match expr {
            Expression::BinaryExpression(binary) => {
                let Some(method) = binary_helper(binary.operator) else {
                    return;
                };
                let span = binary.span;
                let left = binary.left.take_in(&self.ast);
                let right = binary.right.take_in(&self.ast);
                *expr = self.operator(span, method, [left, right]);
            }
            // A negative literal is a number either way.
            Expression::UnaryExpression(unary)
                if unary.operator == UnaryOperator::UnaryNegation
                    && !matches!(
                        unary.argument,
                        Expression::NumericLiteral(_) | Expression::BigIntLiteral(_)
                    ) =>
            {
                let span = unary.span;
                let argument = unary.argument.take_in(&self.ast);
                *expr = self.operator(span, "neg", [argument]);
            }
            Expression::AssignmentExpression(assign) => {
                let Some(method) = assignment_helper(assign.operator) else {
                    return;
                };
                let Some(read) = self.read_of(&assign.left) else {
                    self.refused.get_or_insert((
                        assign.span,
                        "Envio Subgraph can't apply this compound assignment the way \
                         AssemblyScript does: an indexed or computed target would be evaluated \
                         twice. Compute into a local first.",
                    ));
                    return;
                };
                let right = assign.right.take_in(&self.ast);
                assign.right = self.operator(assign.span, method, [read, right]);
                assign.operator = AssignmentOperator::Assign;
            }
            Expression::CallExpression(call) => {
                let Some((class_span, class)) = self.retag_target(call) else {
                    return;
                };
                let span = call.span;
                let value = call.arguments[0].to_expression_mut().take_in(&self.ast);
                let class = Expression::new_identifier(
                    class_span,
                    Ident::from_str_in(&class, &self.ast),
                    &self.ast,
                );
                *expr = self.call(span, RETAG_HELPER, [class, value]);
            }
            _ => {}
        }
    }

    fn visit_function(&mut self, func: &mut Function<'a>, flags: ScopeFlags) {
        walk_mut::walk_function(self, func, flags);
        let params: Vec<&str> = func
            .params
            .items
            .iter()
            .filter_map(|param| match &param.pattern {
                BindingPattern::BindingIdentifier(id) => Some(id.name.as_str()),
                _ => None,
            })
            .collect();
        let Some(body) = func.body.as_mut() else {
            return;
        };
        for statement in body.statements.iter_mut() {
            if let Statement::VariableDeclaration(decl) = statement {
                let redeclares = decl.declarations.iter().any(|declarator| {
                    matches!(&declarator.id, BindingPattern::BindingIdentifier(id) if params.contains(&id.name.as_str()))
                });
                if decl.kind.is_lexical() && redeclares {
                    decl.kind = VariableDeclarationKind::Var;
                }
            }
        }
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
            Statement::ExportDeclaration(export) => match &export.declaration {
                Declaration::ClassDeclaration(class) => Some(class),
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

fn describe<'d>(
    path: &Path,
    source: &str,
    diagnostics: impl Iterator<Item = &'d OxcDiagnostic>,
) -> anyhow::Error {
    let rendered: Vec<String> = diagnostics
        .map(|diagnostic| {
            let span = diagnostic
                .labels
                .first()
                .map(|label| Span::sized(label.offset(), label.len()))
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
    fn routes_operators_through_the_helper() {
        assert_eq!(
            js(
                "export function day(timestamp: i32, total: BigInt, owner: Address): i32 {
  let bucket = timestamp / 86400;
  total += BigInt.fromI32(1);
  if (owner == ZERO || -total < total) {
    return -1;
  }
  return bucket % 7;
}"
            ),
            "export function day(timestamp, total, owner) {
\tlet bucket = __envio_op.div(timestamp, 86400);
\ttotal = __envio_op.add(total, BigInt.fromI32(1));
\tif (__envio_op.eq(owner, ZERO) || __envio_op.lt(__envio_op.neg(total), total)) {
\t\treturn -1;
\t}
\treturn __envio_op.rem(bucket, 7);
}
"
        );
    }

    // Reading an indexed target twice could run its index twice, so this is
    // refused rather than rewritten into something the mapping didn't write.
    #[test]
    fn refuses_a_compound_assignment_into_a_computed_target() {
        assert_eq!(
            refusal("export function f(values: i32[], i: i32): void {\n  values[i++] /= 2;\n}"),
            "src/mapping.ts:2:3: Envio Subgraph can't apply this compound assignment the way \
             AssemblyScript does: an indexed or computed target would be evaluated twice. \
             Compute into a local first."
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
    fn declares_a_local_that_redeclares_a_parameter_with_var() {
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
\t\tvar value = result.value;
\t\treturn CallResult.fromValue(value[0].toBoolean());
\t}
}
"
        );
    }

    // A nested block still shadows the way AssemblyScript scopes it.
    #[test]
    fn keeps_a_nested_redeclaration_block_scoped() {
        assert_eq!(
            js("function f(value: i32): i32 {
  let value = 1;
  if (value > 0) {
    let value = 2;
    return value;
  }
  return value;
}"),
            "function f(value) {
\tvar value = 1;
\tif (__envio_op.gt(value, 0)) {
\t\tlet value = 2;
\t\treturn value;
\t}
\treturn value;
}
"
        );
    }

    // Only a class the module can reach at runtime: the block handler's
    // `ethereum.Block` is a qualified type, and `helper`'s `i32` no class.
    #[test]
    fn exports_the_class_each_handler_declares_for_its_event() {
        assert_eq!(
            js("import { ethereum } from \"@graphprotocol/graph-ts\";
import { Transfer, Approval } from \"../generated/Token/Token\";
export function handleTransfer(event: Transfer): void {}
export function handleApproval(event: Approval): void {}
export function handleBlock(block: ethereum.Block): void {}
export function helper(n: i32): i32 { return n; }"),
            "import { Transfer, Approval } from \"../generated/Token/Token\";
export function handleTransfer(event) {}
export function handleApproval(event) {}
export function handleBlock(block) {}
export function helper(n) {
\treturn n;
}
export const __envio_event_classes = {
\thandleTransfer: Transfer,
\thandleApproval: Approval
};
"
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
