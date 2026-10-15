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
//! - Below apiVersion 0.0.5 graph-node does not null-check an AssemblyScript
//!   pointer (`check_is_not_null` exists only in `asc_abi/v0_0_5.rs`), and asc
//!   0.6 compiles `x!` and a field read without a check. A null `BigInt`,
//!   `BigDecimal` or `Bytes` handed to a host function reads as an empty value,
//!   so `null.plus(x)` is `x`; a field read through a null reference reads
//!   whatever is at that offset in low memory, zero in practice. Such a mapping
//!   gets `a?.b` for every property read and a null-tolerant receiver for the
//!   graph-ts methods that go to the host.
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
    span::{GetSpan, SourceType, Span},
    syntax::{
        operator::{AssignmentOperator, BinaryOperator, UnaryOperator},
        scope::ScopeFlags,
    },
    transformer::{TransformOptions, Transformer},
};

pub const OPERATORS_HELPER: &str = "__envio_op";
pub const RETAG_HELPER: &str = "__envio_retag";
pub const RETAG_EACH_HELPER: &str = "__envio_retag_each";
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

/// AssemblyScript lets a class take a built-in type's name — OpenZeppelin's
/// `@amxx/graphprotocol-utils` declares `export class string extends String {}`
/// in a namespace — which TypeScript's grammar refuses. Such a declaration
/// becomes a class expression bound to a constant of that name, which is
/// legal, and reads the same from outside: `persistent.string`.
fn class_expressions_for_type_names(source: &str) -> String {
    let pattern = regex::Regex::new(
        r"(?m)^([ \t]*)(export[ \t]+)?class[ \t]+(string|number|boolean|symbol|bigint|object|any|unknown|never|void)\b",
    )
    .expect("valid pattern");
    pattern
        .replace_all(source, "${1}${2}const ${3} = class")
        .into_owned()
}

/// AssemblyScript takes a decorator on a top-level function or variable —
/// Beefy writes `@inline` above its helpers — which TypeScript's grammar
/// refuses. Those are blanked to spaces before parsing, so every offset the
/// source map records stays where it was. A decorator on a class or a member
/// parses as it is and is dropped with the rest.
fn blank_statement_decorators(source: &str) -> String {
    fn decorator_len(text: &str) -> Option<usize> {
        let rest = text.strip_prefix('@')?;
        let name = rest
            .find(|c: char| !(c.is_alphanumeric() || c == '_' || c == '$' || c == '.'))
            .unwrap_or(rest.len());
        if name == 0 {
            return None;
        }
        let mut len = 1 + name;
        if text[len..].starts_with('(') {
            len += text[len..].find(')')? + 1;
        }
        Some(len)
    }
    fn declares_statement(text: &str) -> bool {
        let mut text = text.trim_start();
        for prefix in ["export ", "declare "] {
            if let Some(rest) = text.strip_prefix(prefix) {
                text = rest.trim_start();
            }
        }
        ["function", "let ", "const ", "var ", "namespace ", "enum "]
            .iter()
            .any(|keyword| text.starts_with(keyword))
    }

    let mut out = source.to_string();
    let lines: Vec<(usize, &str)> = source
        .split_inclusive('\n')
        .scan(0, |offset, line| {
            let start = *offset;
            *offset += line.len();
            Some((start, line))
        })
        .collect();
    for (index, (start, line)) in lines.iter().enumerate() {
        let indent = line.len() - line.trim_start().len();
        let mut at = indent;
        let mut decorators = vec![];
        while let Some(len) = decorator_len(&line[at..]) {
            decorators.push((start + at, len));
            at += len;
            at += line[at..].len() - line[at..].trim_start_matches([' ', '\t']).len();
        }
        if decorators.is_empty() {
            continue;
        }
        let tail = line[at..].trim();
        let follows = if tail.is_empty() {
            // The decorated statement starts on a later line, past any other
            // decorators and comments.
            lines[index + 1..]
                .iter()
                .map(|(_, next)| next.trim())
                .find(|next| !next.is_empty() && !next.starts_with("//") && !next.starts_with('@'))
                .is_some_and(declares_statement)
        } else {
            declares_statement(tail)
        };
        if follows {
            for (offset, len) in decorators {
                out.replace_range(offset..offset + len, &" ".repeat(len));
            }
        }
    }
    out
}

/// The JavaScript to run for one AssemblyScript file, with an inline source map
/// back to the original so a mapping's stack trace names its own lines.
pub fn to_javascript(source: &str, path: &Path, legacy_nulls: bool) -> Result<String> {
    let blanked = blank_statement_decorators(&class_expressions_for_type_names(source));
    let source = blanked.as_str();
    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, source, SourceType::ts()).parse();
    if parsed.panicked || parsed.diagnostics.has_errors() {
        return Err(describe(path, source, parsed.diagnostics.errors()));
    }
    let mut program = parsed.program;
    drop_reimported_names(&mut program);

    let mut rewrite = Rewrite {
        ast: AstBuilder::new(&allocator),
        classes: value_bindings(&program),
        refused: None,
        legacy_nulls,
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
        .with_enum_eval(true)
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
    /// The mapping is below apiVersion 0.0.5, where graph-node reads through a
    /// null pointer instead of trapping.
    legacy_nulls: bool,
}

/// graph-ts methods whose receiver goes to the host as a pointer, or whose
/// result on an empty value is plain: below apiVersion 0.0.5 a null receiver
/// is a zero (or empty) one. The runtime's `recv` decides which.
const NULL_RECEIVER_METHODS: &[&str] = &[
    "plus",
    "minus",
    "times",
    "div",
    "mod",
    "pow",
    "bitOr",
    "bitAnd",
    "leftShift",
    "rightShift",
    "abs",
    "neg",
    "truncate",
    "toString",
    "toHex",
    "toHexString",
    "toI32",
    "toBigDecimal",
    "isZero",
    "equals",
    "notEqual",
    "lt",
    "le",
    "gt",
    "ge",
];

/// The `OPERATORS_HELPER` method standing in for a binary operator.
fn binary_helper(operator: BinaryOperator) -> Option<&'static str> {
    Some(match operator {
        BinaryOperator::Addition => "add",
        BinaryOperator::Subtraction => "sub",
        BinaryOperator::Multiplication => "mul",
        BinaryOperator::Division => "div",
        BinaryOperator::Remainder => "rem",
        BinaryOperator::Exponential => "pow",
        BinaryOperator::Equality => "eq",
        BinaryOperator::Inequality => "ne",
        BinaryOperator::LessThan => "lt",
        BinaryOperator::LessEqualThan => "le",
        BinaryOperator::GreaterThan => "gt",
        BinaryOperator::GreaterEqualThan => "ge",
        _ => return None,
    })
}

/// The `OPERATORS_HELPER` method standing in for `x.indexOf(v)` and its kin:
/// AssemblyScript's array searches compare with `==`, so graph-ts' overload.
fn search_helper(call: &CallExpression<'_>) -> Option<&'static str> {
    let Expression::StaticMemberExpression(member) = &call.callee else {
        return None;
    };
    if call.optional
        || member.optional
        || matches!(member.object, Expression::Super(_))
        || !(1..=2).contains(&call.arguments.len())
        || call
            .arguments
            .iter()
            .any(|argument| matches!(argument, Argument::SpreadElement(_)))
    {
        return None;
    }
    Some(match member.property.name.as_str() {
        "includes" => "includes",
        "indexOf" => "indexOf",
        "lastIndexOf" => "lastIndexOf",
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
        AssignmentOperator::Exponential => "pow",
        _ => return None,
    })
}

impl<'a> Rewrite<'a> {
    /// Visits what a member-expression callee reads, not the callee itself.
    fn visit_callee(&mut self, callee: &mut Expression<'a>) {
        match callee {
            Expression::StaticMemberExpression(member) => self.visit_expression(&mut member.object),
            Expression::ComputedMemberExpression(member) => {
                self.visit_expression(&mut member.object);
                self.visit_expression(&mut member.expression);
            }
            other => self.visit_expression(other),
        }
    }

    /// A property read becomes an optional one (`a.b.c` is `a?.b?.c`), as a
    /// read through a null pointer yields nothing instead of trapping. A
    /// callee, an assignment target and `this.x` keep their own form.
    fn read_through_null(&self, expr: &mut Expression<'a>) {
        fn reaches_through(object: &Expression<'_>) -> bool {
            !matches!(object, Expression::ThisExpression(_) | Expression::Super(_))
        }
        fn mark(expr: &mut Expression<'_>) {
            let object = match expr {
                Expression::StaticMemberExpression(member) if reaches_through(&member.object) => {
                    member.optional = true;
                    &mut member.object
                }
                Expression::ComputedMemberExpression(member) if reaches_through(&member.object) => {
                    member.optional = true;
                    &mut member.object
                }
                _ => return,
            };
            mark(object);
        }
        let eligible = match expr {
            Expression::StaticMemberExpression(member) => {
                !member.optional && reaches_through(&member.object)
            }
            Expression::ComputedMemberExpression(member) => {
                !member.optional && reaches_through(&member.object)
            }
            _ => false,
        };
        if !eligible {
            return;
        }
        mark(expr);
        let span = expr.span();
        let taken = expr.take_in(&self.ast);
        let element = match taken {
            Expression::StaticMemberExpression(member) => {
                ChainElement::StaticMemberExpression(member)
            }
            Expression::ComputedMemberExpression(member) => {
                ChainElement::ComputedMemberExpression(member)
            }
            other => {
                *expr = other;
                return;
            }
        };
        *expr = Expression::new_chain_expression(span, element, &self.ast);
    }

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
            // `w[i] += x`, `w[(i + 9) & 15] ^= y`: reading the element again
            // costs nothing when neither the object nor the index does anything.
            AssignmentTarget::ComputedMemberExpression(member)
                if is_pure(&member.object) && is_effect_free(&member.expression) =>
            {
                Some(Expression::ComputedMemberExpression(
                    member.clone_in(self.ast.allocator()),
                ))
            }
            _ => None,
        }
    }

    /// The element class `x.toTupleArray<Foo>()` names: graph codegen reads a
    /// struct array that way, and the elements are `Foo`s in AssemblyScript.
    fn element_retag_target(&self, call: &CallExpression<'a>) -> Option<(Span, String)> {
        let Expression::StaticMemberExpression(member) = &call.callee else {
            return None;
        };
        if !matches!(
            member.property.name.as_str(),
            "toTupleArray" | "toTupleMatrix"
        ) {
            return None;
        }
        let class = class_ref(call.type_arguments.as_ref()?.params.first()?, &self.classes)?;
        Some((class.span, class.name.to_string()))
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

/// An expression whose evaluation changes nothing and can be evaluated twice:
/// names, literals, reads, and arithmetic over them (including the operator
/// helper calls this pass has already put in their place).
fn is_effect_free(expr: &Expression<'_>) -> bool {
    match expr {
        Expression::Identifier(_)
        | Expression::ThisExpression(_)
        | Expression::NumericLiteral(_)
        | Expression::BigIntLiteral(_)
        | Expression::StringLiteral(_)
        | Expression::BooleanLiteral(_)
        | Expression::NullLiteral(_) => true,
        Expression::StaticMemberExpression(member) => is_effect_free(&member.object),
        Expression::ComputedMemberExpression(member) => {
            is_effect_free(&member.object) && is_effect_free(&member.expression)
        }
        Expression::ParenthesizedExpression(paren) => is_effect_free(&paren.expression),
        Expression::BinaryExpression(binary) => {
            is_effect_free(&binary.left) && is_effect_free(&binary.right)
        }
        Expression::UnaryExpression(unary) => {
            unary.operator != UnaryOperator::Delete && is_effect_free(&unary.argument)
        }
        Expression::TSAsExpression(cast) => is_effect_free(&cast.expression),
        Expression::TSNonNullExpression(inner) => is_effect_free(&inner.expression),
        Expression::CallExpression(call) => {
            matches!(&call.callee, Expression::StaticMemberExpression(member)
                if matches!(&member.object, Expression::Identifier(id) if id.name == OPERATORS_HELPER))
                && call
                    .arguments
                    .iter()
                    .all(|arg| arg.as_expression().is_some_and(is_effect_free))
        }
        _ => false,
    }
}

impl<'a> VisitMut<'a> for Rewrite<'a> {
    fn visit_expression(&mut self, expr: &mut Expression<'a>) {
        if self.legacy_nulls {
            self.read_through_null(expr);
        }
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
            // graph-cli before 0.2x's tuple getters, and old entity loads, cast
            // with `as` rather than `changetype`: the same reinterpret, except
            // that a value already of the class (an upcast) keeps its own.
            Expression::TSAsExpression(cast) => {
                // `x as i32` converts: a wider integer wraps, a null is 0, and a
                // reference is its address, which JavaScript has no number for.
                let integer = match &cast.type_annotation {
                    TSType::TSTypeReference(reference) => match &reference.type_name {
                        TSTypeName::IdentifierReference(ty) => match ty.name.as_str() {
                            "i8" => Some("as_i8"),
                            "u8" => Some("as_u8"),
                            "i16" => Some("as_i16"),
                            "u16" => Some("as_u16"),
                            "i32" => Some("as_i32"),
                            "u32" => Some("as_u32"),
                            _ => None,
                        },
                        _ => None,
                    },
                    _ => None,
                };
                if let Some(method) = integer {
                    let span = cast.span;
                    let value = cast.expression.take_in(&self.ast);
                    *expr = self.operator(span, method, [value]);
                    return;
                }
                let class = match &cast.type_annotation {
                    TSType::TSUnionType(union) => union
                        .types
                        .iter()
                        .find_map(|ty| class_ref(ty, &self.classes)),
                    ty => class_ref(ty, &self.classes),
                };
                let Some(class) = class.map(|class| (class.span, class.name.to_string())) else {
                    return;
                };
                let span = cast.span;
                let value = cast.expression.take_in(&self.ast);
                let ctor = Expression::new_identifier(
                    class.0,
                    Ident::from_str_in(&class.1, &self.ast),
                    &self.ast,
                );
                let keep = Expression::new_boolean_literal(span, true, &self.ast);
                *expr = self.call(span, RETAG_HELPER, [ctor, value, keep]);
            }
            Expression::CallExpression(call) => {
                if self.legacy_nulls {
                    if let Expression::StaticMemberExpression(member) = &mut call.callee {
                        if !member.optional
                            && !matches!(
                                member.object,
                                Expression::Super(_) | Expression::ThisExpression(_)
                            )
                            && NULL_RECEIVER_METHODS.contains(&member.property.name.as_str())
                        {
                            let span = member.span;
                            let object = member.object.take_in(&self.ast);
                            member.object = self.operator(span, "recv", [object]);
                            return;
                        }
                    }
                }
                if let Some(method) = search_helper(call) {
                    let span = call.span;
                    let Expression::StaticMemberExpression(member) = &mut call.callee else {
                        return;
                    };
                    let mut args = vec![member.object.take_in(&self.ast)];
                    args.extend(
                        call.arguments
                            .iter_mut()
                            .map(|argument| argument.to_expression_mut().take_in(&self.ast)),
                    );
                    let object = Expression::new_identifier(span, OPERATORS_HELPER, &self.ast);
                    let property = IdentifierName::new(span, method, &self.ast);
                    let callee = Expression::new_static_member_expression(
                        span, object, property, false, &self.ast,
                    );
                    let args =
                        ArenaVec::from_iter_in(args.into_iter().map(Argument::from), &self.ast);
                    *expr =
                        Expression::new_call_expression(span, callee, None, args, false, &self.ast);
                    return;
                }
                if let Some((class_span, class)) = self.element_retag_target(call) {
                    let span = call.span;
                    let value = expr.take_in(&self.ast);
                    let class = Expression::new_identifier(
                        class_span,
                        Ident::from_str_in(&class, &self.ast),
                        &self.ast,
                    );
                    *expr = self.call(span, RETAG_EACH_HELPER, [class, value]);
                    return;
                }
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

    // A callee keeps its form, or the call loses its receiver: `(a?.b)()` is
    // not `a.b()`. Its object is a read like any other.
    fn visit_call_expression(&mut self, call: &mut CallExpression<'a>) {
        if self.legacy_nulls {
            self.visit_callee(&mut call.callee);
            if let Some(type_arguments) = &mut call.type_arguments {
                self.visit_ts_type_parameter_instantiation(type_arguments);
            }
            self.visit_arguments(&mut call.arguments);
        } else {
            walk_mut::walk_call_expression(self, call);
        }
    }

    fn visit_new_expression(&mut self, new: &mut NewExpression<'a>) {
        if self.legacy_nulls {
            self.visit_callee(&mut new.callee);
            if let Some(type_arguments) = &mut new.type_arguments {
                self.visit_ts_type_parameter_instantiation(type_arguments);
            }
            self.visit_arguments(&mut new.arguments);
        } else {
            walk_mut::walk_new_expression(self, new);
        }
    }

    fn visit_class_heritage(&mut self, heritage: &mut ClassHeritage<'a>) {
        if self.legacy_nulls {
            self.visit_callee(&mut heritage.expression);
        } else {
            walk_mut::walk_class_heritage(self, heritage);
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

/// AssemblyScript accepts a name imported more than once — mappings import the
/// same generated event class from two contracts' bindings — but a JavaScript
/// module can't bind it twice. The first import keeps the name; a later one
/// still loads its module.
fn drop_reimported_names(program: &mut Program<'_>) {
    let mut bound = HashSet::new();
    for statement in program.body.iter_mut() {
        let Statement::ImportDeclaration(import) = statement else {
            continue;
        };
        if let Some(specifiers) = import.specifiers.as_mut() {
            specifiers.retain(|specifier| bound.insert(specifier.local().name.to_string()));
            if specifiers.is_empty() {
                import.specifiers = None;
            }
        }
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
        let out =
            to_javascript(source, Path::new("src/mapping.ts"), false).expect("a readable mapping");
        out.split("//# sourceMappingURL=")
            .next()
            .unwrap()
            .to_string()
    }

    fn legacy_js(source: &str) -> String {
        let out =
            to_javascript(source, Path::new("src/mapping.ts"), true).expect("a readable mapping");
        out.split("//# sourceMappingURL=")
            .next()
            .unwrap()
            .to_string()
    }

    #[test]
    fn reads_through_null_below_api_version_0_0_5() {
        let source = "export function f(defs: Def[], p: Position): void {
  let a = defs[i].address.toHexString();
  p.premium = p.premium.plus(x);
  p.count = this.count;
  let c = new ns.Thing(p.id);
}";
        let out = legacy_js(source);
        assert_eq!(
            [
                out.contains("defs?.[i]?.address"),
                out.contains("__envio_op.recv(defs?.[i]?.address).toHexString()"),
                out.contains("__envio_op.recv(p?.premium).plus(x)"),
                out.contains("= this.count"),
                out.contains("new ns.Thing(p?.id)"),
            ],
            [true; 5],
            "{out}"
        );
        assert!(!js(source).contains("?."), "gated off, nothing changes");
    }

    fn refusal(source: &str) -> String {
        to_javascript(source, Path::new("src/mapping.ts"), false)
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

    #[test]
    fn routes_a_power_through_the_helper() {
        let out = js("export function f(b: i64): i64 {
  let c = 10 ** b;
  c **= 2;
  return c;
}");
        assert!(
            out.contains("__envio_op.pow(10, b)") && out.contains("c = __envio_op.pow(c, 2)"),
            "{out}"
        );
    }

    #[test]
    fn routes_array_searches_through_the_helper() {
        assert_eq!(
            js("export function has(resolver: Resolver, coinType: BigInt): bool {
  let at = resolver.coinTypes!.indexOf(coinType, 1);
  return resolver.coinTypes!.includes(coinType) || names().lastIndexOf(\"a\") > at || list.find(coinType);
}"),
            "export function has(resolver, coinType) {
\tlet at = __envio_op.indexOf(resolver.coinTypes, coinType, 1);
\treturn __envio_op.includes(resolver.coinTypes, coinType) || __envio_op.gt(__envio_op.lastIndexOf(names(), \"a\"), at) || list.find(coinType);
}
"
        );
    }

    // AssemblyScript accepts a name imported twice; a JavaScript module that
    // declares the binding twice doesn't load. The first import wins.
    #[test]
    fn drops_a_name_imported_again() {
        assert_eq!(
            js("import { Farmed } from \"./a\";
import { Farmed } from \"./b\";
export function handleFarmed(event: Farmed): void {}"),
            "import { Farmed } from \"./a\";
import \"./b\";
export function handleFarmed(event) {}
export const __envio_event_classes = { handleFarmed: Farmed };
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

    // Kiln's sha256 expands its message schedule with `w[i] += w[(i + 9) & 15] + …`:
    // an element target whose object and index are plain reads is read again.
    #[test]
    fn applies_a_compound_assignment_to_an_element_with_a_plain_index() {
        assert_eq!(
            js("export function f(w: StaticArray<u32>, i: i32): void {
  w[i] += w[(i + 9) & 15];
  w[(i + 1) & 15] ^= 3;
}"),
            "export function f(w, i) {
\tw[i] = __envio_op.add(w[i], w[__envio_op.add(i, 9) & 15]);
\tw[__envio_op.add(i, 1) & 15] ^= 3;
}
"
        );
    }

    #[test]
    fn retags_an_as_cast_onto_a_class_it_can_reach() {
        assert_eq!(
            js("import { Pair } from \"../generated/schema\";
export function f(value: ethereum.Tuple, n: i64): void {
  let pair = value as Pair;
  let maybe = value as Pair | null;
  let wide = n as i32;
}"),
            "import { Pair } from \"../generated/schema\";
export function f(value, n) {
\tlet pair = __envio_retag(Pair, value, true);
\tlet maybe = __envio_retag(Pair, value, true);
\tlet wide = __envio_op.as_i32(n);
}
"
        );
    }

    #[test]
    fn retags_the_elements_of_a_struct_array() {
        assert_eq!(
            js("import { Item } from \"../generated/Pool/Pool\";
export function f(value: ethereum.Value): void {
  let items = value.toTupleArray<Item>();
  let plain = value.toTupleArray<ethereum.Tuple>();
}"),
            "import { Item } from \"../generated/Pool/Pool\";
export function f(value) {
\tlet items = __envio_retag_each(Item, value.toTupleArray());
\tlet plain = value.toTupleArray();
}
"
        );
    }

    #[test]
    fn takes_a_class_named_after_a_built_in_type() {
        assert_eq!(
            js("export namespace persistent {
  export class string extends String {}
}
export const read = persistent.string;"),
            "export let persistent;
(function(_persistent) {
\tconst string = _persistent.string = class extends String {};
})(persistent || (persistent = {}));
export const read = persistent.string;
"
        );
    }

    #[test]
    fn transforms_an_enum() {
        assert_eq!(
            js("export enum ChainId { MAINNET = 1, BASE = 8453 }
export const base = ChainId.BASE;"),
            "export let ChainId = /* @__PURE__ */ function(ChainId) {
\tChainId[ChainId[\"MAINNET\"] = 1] = \"MAINNET\";
\tChainId[ChainId[\"BASE\"] = 8453] = \"BASE\";
\treturn ChainId;
}({});
export const base = ChainId.BASE;
"
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
    fn drops_a_decorator_on_a_top_level_function() {
        assert_eq!(
            js("// @ts-ignore
@inline
function scaled(amount: i32): i32 {
  return amount;
}
@inline export const TEN: i32 = 10;"),
            "// @ts-ignore
function scaled(amount) {
\treturn amount;
}
export const TEN = 10;
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
        let out = to_javascript(
            "export const a = 1 / 2;",
            Path::new("src/mapping.ts"),
            false,
        )
        .unwrap();
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
