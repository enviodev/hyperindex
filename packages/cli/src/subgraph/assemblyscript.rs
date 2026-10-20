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
//! - `===` can't be overloaded in AssemblyScript: it compares two references by
//!   identity and two numbers by value. JavaScript compares strings by value,
//!   so a string the host just allocated — `dataSource.network() === 'mainnet'`
//!   — is marked at the comparison, where it can never be identical; a literal
//!   is one static segment wherever it is written, so literals stay equal.
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

use std::{
    collections::{HashMap, HashSet},
    path::Path,
};

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
/// AssemblyScript's own `Map` and `Set`, which a mapping's `new Map` builds.
pub const AS_MAP: &str = "__envio_Map";
pub const AS_SET: &str = "__envio_Set";

/// `export function handleTransfer(event: Transfer)` names, in a type, the
/// generated class graph-node would hand it — the class whose `params` getters
/// codegen wrote. Types don't survive into JavaScript, so each exported
/// function's first-parameter class is also exported as a value, keyed by the
/// function's name, for the runtime to build the event as that class. Each is
/// a getter: the class may come from a module still evaluating in an import
/// cycle, whose binding can't be read until it has run.
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
            Some(format!("get {name}() {{ return {}; }}", class.name))
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
    transform(source, path, legacy_nulls, true)
}

fn transform(source: &str, path: &Path, legacy_nulls: bool, hoist: bool) -> Result<String> {
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
        module_names: module_names(&program),
        locals: vec![],
        generics: vec![],
        in_for_head: false,
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
    if hoist {
        module_lifecycle(&mut program, &allocator);
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

const STATIC_INIT: &str = "__envio_static";
const START: &str = "__envio_start";
pub const MODULE_INIT: &str = "__envio_init";
const PLACEHOLDER: &str = "__envio_placeholder";

/// The graph-ts classes whose values a mapping never changes in place, so a
/// global built from them reads the same in every trigger.
const VALUE_CLASSES: &[&str] = &["BigInt", "BigDecimal", "Address", "Bytes", "ByteArray"];

/// graph-node instantiates a mapping's WASM module for every trigger
/// (runtime/wasm/src/mapping.rs: `instantiate_module` before each
/// `handle_trigger`), so a file's top-level code — its start function — runs
/// again in each trigger's context, and nothing a handler leaves in a global
/// survives into the next one. And it compiles to more than one stage: a class
/// and a global whose initializer is a constant exist before any top-level code
/// runs (asc gives such a global that value as its initial one; only other
/// initializers run in the start function).
///
/// An ES module is evaluated once, and its classes and `const`s are in their
/// temporal dead zone until its body reaches them: in an import cycle (Opolis'
/// `Token.ts` ⇄ `ERC20/index.ts`, Flaunch's `addresses/index.ts` ⇄ `base.ts`)
/// the file evaluated first threw where asc reads the value. So the module is
/// rewritten into those stages:
///
/// - `__envio_static()`: the classes whose definition runs no code, the
///   constant globals, and the globals built from graph-ts values
///   (`BigInt.fromI32(0)`, `Address.fromString("0x…")`) — the same in every
///   trigger, so set once. It first calls the same function of each relative
///   module this one imports or re-exports, and a module calls it before its
///   own top-level code. A function declaration exists once the module graph is
///   linked, so a cyclic importer reaches it while the module itself hasn't run.
/// - `__envio_start(again)`: every other top-level statement, in order, a
///   declaration turned into an assignment of its `var` — the start function.
///   It runs as the module loads, without failing the load: graph-node runs it
///   in a trigger's context, which the load only stands in for
///   (`dataSource.context()` of a template instance). And again through
///   `__envio_init(generation)`, which the runtime calls as each trigger's
///   handler starts, after the same function of every module this one imports
///   — but only what can differ by then: a `let`, an exported global or one
///   the module changes in place, a statement, and what reads `dataSource` or
///   one of those. A table a handler only reads (Kiln's BLS curve constants)
///   is built once; rebuilding it in every trigger, as graph-node does, can't
///   be observed.
fn module_lifecycle<'a>(program: &mut Program<'a>, allocator: &'a Allocator) {
    use std::collections::HashMap;

    fn constant(expr: &Expression<'_>, known: &HashMap<String, bool>) -> Option<bool> {
        // `Some(true)` for a number-like constant, `Some(false)` for text.
        let number = |expr: &Expression<'_>| constant(expr, known) == Some(true);
        match expr {
            Expression::StringLiteral(_) => Some(false),
            Expression::TemplateLiteral(template) if template.expressions.is_empty() => Some(false),
            Expression::NumericLiteral(_)
            | Expression::BigIntLiteral(_)
            | Expression::BooleanLiteral(_)
            | Expression::NullLiteral(_) => Some(true),
            Expression::ParenthesizedExpression(paren) => constant(&paren.expression, known),
            Expression::UnaryExpression(unary)
                if matches!(
                    unary.operator,
                    UnaryOperator::UnaryNegation
                        | UnaryOperator::UnaryPlus
                        | UnaryOperator::BitwiseNot
                        | UnaryOperator::LogicalNot
                ) && number(&unary.argument) =>
            {
                Some(true)
            }
            Expression::BinaryExpression(binary)
                if number(&binary.left) && number(&binary.right) =>
            {
                Some(true)
            }
            // `1 + 2`, `5 as u8`: arithmetic this pass already routed through
            // the operator helper.
            Expression::CallExpression(call)
                if is_operator_helper(&call.callee)
                    && call
                        .arguments
                        .iter()
                        .all(|argument| argument.as_expression().is_some_and(number)) =>
            {
                Some(true)
            }
            Expression::Identifier(id) => known.get(id.name.as_str()).copied(),
            _ => None,
        }
    }
    fn is_operator_helper(callee: &Expression<'_>) -> bool {
        matches!(callee, Expression::StaticMemberExpression(member)
            if matches!(&member.object, Expression::Identifier(id) if id.name == OPERATORS_HELPER))
    }
    /// A graph-ts value built from constants and other such values.
    fn graph_value(
        expr: &Expression<'_>,
        constants: &HashMap<String, bool>,
        values: &HashSet<String>,
        value_classes: &HashSet<String>,
    ) -> bool {
        let value = |expr: &Expression<'_>| graph_value(expr, constants, values, value_classes);
        let arguments = |arguments: &ArenaVec<'_, Argument<'_>>| {
            arguments
                .iter()
                .all(|argument| argument.as_expression().is_some_and(value))
        };
        match expr {
            Expression::Identifier(id) if values.contains(id.name.as_str()) => true,
            Expression::ParenthesizedExpression(paren) => value(&paren.expression),
            Expression::CallExpression(call) if !call.optional => match &call.callee {
                callee if is_operator_helper(callee) => arguments(&call.arguments),
                Expression::StaticMemberExpression(member) => {
                    let factory = matches!(&member.object, Expression::Identifier(class)
                        if value_classes.contains(class.name.as_str()));
                    (factory || value(&member.object)) && arguments(&call.arguments)
                }
                _ => false,
            },
            Expression::NewExpression(new) => {
                matches!(&new.callee, Expression::Identifier(class)
                    if value_classes.contains(class.name.as_str()))
                    && arguments(&new.arguments)
            }
            other => constant(other, constants).is_some(),
        }
    }
    /// oxc's lowering of a TypeScript enum: `let E = function(E) {…}({})`.
    fn is_enum(expr: &Expression<'_>) -> bool {
        let Expression::CallExpression(call) = expr else {
            return false;
        };
        matches!(
            call.callee.without_parentheses(),
            Expression::FunctionExpression(_)
        ) && matches!(call.arguments.as_slice(), [Argument::ObjectExpression(object)] if object.properties.is_empty())
    }
    fn plain_name(expr: &Expression<'_>) -> bool {
        match expr {
            Expression::Identifier(_) => true,
            Expression::StaticMemberExpression(member) => plain_name(&member.object),
            _ => false,
        }
    }
    fn is_literal(value: &Expression<'_>) -> bool {
        matches!(
            value,
            Expression::NumericLiteral(_)
                | Expression::BooleanLiteral(_)
                | Expression::NullLiteral(_)
                | Expression::StringLiteral(_)
        )
    }
    fn runs_nothing(class: &Class<'_>) -> bool {
        // A static field's literal — the zero `Rewrite` gives one without an
        // initializer — runs nothing; `__envio_start` sets it again.
        let literal = |value: &Option<Expression<'_>>| value.as_ref().is_none_or(is_literal);
        class.id.is_some()
            && class
                .heritage
                .as_ref()
                .is_none_or(|heritage| plain_name(&heritage.expression))
            && class.body.body.iter().all(|element| match element {
                ClassElement::StaticBlock(_) => false,
                ClassElement::PropertyDefinition(property) => {
                    !property.computed && !(property.r#static && !literal(&property.value))
                }
                ClassElement::AccessorProperty(property) => {
                    !property.computed && !(property.r#static && !literal(&property.value))
                }
                ClassElement::MethodDefinition(method) => !method.computed,
                _ => true,
            })
    }
    fn request<'s>(statement: &'s Statement<'_>) -> Option<&'s str> {
        let source = match statement {
            Statement::ImportDeclaration(import) => &import.source,
            Statement::ExportAllDeclaration(export) => &export.source,
            Statement::ExportFromDeclaration(export) => &export.source,
            _ => return None,
        };
        source
            .value
            .starts_with('.')
            .then_some(source.value.as_str())
    }

    // Spans of the parsed text point into it, not into the mapping, and the
    // source map refuses positions past the mapping's end.
    struct Unplaced;
    impl<'a> VisitMut<'a> for Unplaced {
        fn visit_span(&mut self, span: &mut Span) {
            *span = Span::default();
        }
    }
    let parse = |text: &str| -> ArenaVec<'a, Statement<'a>> {
        let text = allocator.alloc_str(text);
        let mut body = Parser::new(allocator, text, SourceType::mjs())
            .parse()
            .program
            .body;
        for statement in body.iter_mut() {
            Unplaced.visit_statement(statement);
        }
        body
    };
    struct Fill<'a> {
        value: Option<Expression<'a>>,
    }
    impl<'a> VisitMut<'a> for Fill<'a> {
        fn visit_expression(&mut self, expr: &mut Expression<'a>) {
            if matches!(expr, Expression::Identifier(id) if id.name == PLACEHOLDER) {
                if let Some(value) = self.value.take() {
                    *expr = value;
                }
                return;
            }
            walk_mut::walk_expression(self, expr);
        }
    }
    let filled = |text: &str, value: Expression<'a>| -> ArenaVec<'a, Statement<'a>> {
        let mut statements = parse(text);
        let mut fill = Fill { value: Some(value) };
        for statement in statements.iter_mut() {
            fill.visit_statement(statement);
        }
        statements
    };

    let value_classes: HashSet<String> = program
        .body
        .iter()
        .filter_map(|statement| match statement {
            Statement::ImportDeclaration(import)
                if import.source.value == "@graphprotocol/graph-ts" =>
            {
                Some(import.specifiers.iter().flatten())
            }
            _ => None,
        })
        .flatten()
        .filter_map(|specifier| match specifier {
            ImportDeclarationSpecifier::ImportSpecifier(specifier)
                if VALUE_CLASSES.contains(&specifier.imported.name().as_str()) =>
            {
                Some(specifier.local.name.to_string())
            }
            _ => None,
        })
        .collect();

    let ast = AstBuilder::new(allocator);
    let mutated = mutated_names(program);
    let old = std::mem::replace(&mut program.body, ArenaVec::new_in(&ast));
    let mut constants: HashMap<String, bool> = HashMap::new();
    let mut values: HashSet<String> = HashSet::new();
    let mut declared: Vec<(String, bool)> = vec![];
    let mut static_init = ArenaVec::new_in(&ast);
    let mut definers = ArenaVec::new_in(&ast);
    // Each start statement, and whether it runs again in every trigger: what
    // keeps state or reads the trigger's context. The rest — tables a handler
    // only reads — build once; graph-node's rebuild of them is unobservable.
    let mut start: Vec<(Statement<'a>, bool)> = vec![];
    let mut per_trigger: HashSet<String> = HashSet::new();
    let reruns = |expr: &Expression<'_>, per_trigger: &HashSet<String>| {
        let mut names = References::default();
        oxc::ast_visit::Visit::visit_expression(&mut names, expr);
        names.0.contains("dataSource") || names.0.iter().any(|name| per_trigger.contains(name))
    };
    let mut body = ArenaVec::new_in(&ast);
    let mut deps: Vec<String> = vec![];
    for statement in old {
        if let Some(request) = request(&statement).map(str::to_string) {
            body.push(statement);
            if !deps.contains(&request) {
                let source = serde_json::to_string(&request).expect("a string");
                body.extend(parse(&format!(
                    "import * as __envio_dep_{} from {source};",
                    deps.len()
                )));
                deps.push(request);
            }
            continue;
        }
        let plain_variables = |decl: &VariableDeclaration<'_>| {
            !decl.declare
                && decl.declarations.iter().all(|declarator| {
                    matches!(&declarator.id, BindingPattern::BindingIdentifier(id) if id.name != EVENT_CLASSES_EXPORT)
                })
        };
        let named_class = |class: &Class<'_>| class.id.is_some() && !class.declare;
        let handled = match &statement {
            Statement::VariableDeclaration(decl) => plain_variables(decl),
            Statement::ClassDeclaration(class) => named_class(class),
            Statement::ExportDeclaration(export) => match &export.declaration {
                Declaration::VariableDeclaration(decl) => plain_variables(decl),
                Declaration::ClassDeclaration(class) => named_class(class),
                _ => false,
            },
            Statement::ExpressionStatement(_)
            | Statement::IfStatement(_)
            | Statement::ForStatement(_)
            | Statement::ForInStatement(_)
            | Statement::ForOfStatement(_)
            | Statement::WhileStatement(_)
            | Statement::DoWhileStatement(_)
            | Statement::BlockStatement(_)
            | Statement::SwitchStatement(_)
            | Statement::TryStatement(_)
            | Statement::ThrowStatement(_)
            | Statement::LabeledStatement(_) => {
                start.push((statement, true));
                continue;
            }
            _ => false,
        };
        if !handled {
            body.push(statement);
            continue;
        }
        let (declaration, exported) = match statement {
            Statement::VariableDeclaration(decl) => (Declaration::VariableDeclaration(decl), false),
            Statement::ClassDeclaration(class) => (Declaration::ClassDeclaration(class), false),
            Statement::ExportDeclaration(export) => (export.unbox().declaration, true),
            _ => unreachable!("only declarations are handled"),
        };
        match declaration {
            Declaration::VariableDeclaration(mut decl) => {
                let mutable = decl.kind != VariableDeclarationKind::Const;
                for declarator in decl.declarations.iter_mut() {
                    let BindingPattern::BindingIdentifier(id) = &declarator.id else {
                        continue;
                    };
                    let name = id.name.to_string();
                    declared.push((name.clone(), exported));
                    let Some(init) = declarator.init.take() else {
                        continue;
                    };
                    let assign = format!("{name} = {PLACEHOLDER};");
                    if let Some(kind) = constant(&init, &constants) {
                        if mutable {
                            per_trigger.insert(name.clone());
                            start.extend(
                                filled(&assign, init.clone_in(allocator))
                                    .into_iter()
                                    .map(|statement| (statement, true)),
                            );
                        } else {
                            constants.insert(name, kind);
                        }
                        static_init.extend(filled(&assign, init));
                    } else if is_enum(&init)
                        || (!mutable && graph_value(&init, &constants, &values, &value_classes))
                    {
                        values.insert(name);
                        static_init.extend(filled(&assign, init));
                    } else {
                        // An exported global may be changed in place by an importer.
                        let every = mutable
                            || exported
                            || mutated.contains(&name)
                            || reruns(&init, &per_trigger);
                        if every {
                            per_trigger.insert(name.clone());
                        }
                        start.extend(
                            filled(&assign, init)
                                .into_iter()
                                .map(|statement| (statement, every)),
                        );
                    }
                }
            }
            Declaration::ClassDeclaration(mut class) => {
                let name = class.id.as_ref().expect("a named class").name.to_string();
                declared.push((name.clone(), exported));
                let hoisted = runs_nothing(&class);
                // A mutable static field starts each trigger at its initial value.
                let resets: Vec<String> = class
                    .body
                    .body
                    .iter()
                    .filter_map(|element| match element {
                        ClassElement::PropertyDefinition(property)
                            if hoisted && property.r#static =>
                        {
                            let key = property.key.static_name()?;
                            let value = literal_text(property.value.as_ref()?)?;
                            Some(format!("{name}.{key} = {value};"))
                        }
                        _ => None,
                    })
                    .collect();
                class.r#type = ClassType::ClassExpression;
                let class = Expression::ClassExpression(class);
                if hoisted {
                    definers.extend(filled(
                        &format!(
                            "function __envio_define_{name}() {{ if ({name} === undefined) {name} = {PLACEHOLDER}; }}"
                        ),
                        class,
                    ));
                    static_init.extend(parse(&format!(
                        "try {{ __envio_define_{name}(); }} catch {{}}"
                    )));
                    // Its own place, should the early definition have thrown.
                    start.extend(
                        parse(&format!("__envio_define_{name}();"))
                            .into_iter()
                            .map(|statement| (statement, false)),
                    );
                    for reset in resets {
                        start.extend(parse(&reset).into_iter().map(|statement| (statement, true)));
                    }
                } else {
                    let every = mutated.contains(&name) || reruns(&class, &per_trigger);
                    if every {
                        per_trigger.insert(name.clone());
                    }
                    start.extend(
                        filled(&format!("{name} = {PLACEHOLDER};"), class)
                            .into_iter()
                            .map(|statement| (statement, every)),
                    );
                }
            }
            _ => unreachable!("only variables and classes are handled"),
        }
    }
    if declared.is_empty() && start.is_empty() && deps.is_empty() {
        program.body = body;
        return;
    }

    let declarations: String = declared
        .iter()
        .map(|(name, exported)| {
            let export = if *exported { "export " } else { "" };
            format!("{export}var {name};\n")
        })
        .collect();
    let calls = |function: &str, argument: &str| -> String {
        (0..deps.len())
            .map(|index| format!("__envio_dep_{index}.{function}?.({argument});\n"))
            .collect()
    };
    let mut prelude = parse(&format!(
        "{declarations}var {STATIC_INIT}_state;
export function {STATIC_INIT}() {{
  if ({STATIC_INIT}_state) return;
  {STATIC_INIT}_state = 1;
  {}}}
function {START}(again) {{}}
var {MODULE_INIT}_generation;
export function {MODULE_INIT}(generation) {{
  if ({MODULE_INIT}_generation === generation) return;
  {MODULE_INIT}_generation = generation;
  {}{START}(true);
}}
{STATIC_INIT}();
try {{ {START}(false); }} catch {{}}",
        calls(STATIC_INIT, ""),
        calls(MODULE_INIT, "generation"),
    ));
    let mut bodies = prelude.iter_mut().filter_map(|statement| match statement {
        Statement::ExportDeclaration(export) => match &mut export.declaration {
            Declaration::FunctionDeclaration(func) => func.body.as_mut(),
            _ => None,
        },
        Statement::FunctionDeclaration(func) => func.body.as_mut(),
        _ => None,
    });
    if let Some(function) = bodies.next() {
        function.statements.extend(static_init);
    }
    if let Some(function) = bodies.next() {
        // Consecutive statements that run once share one `if (!again)`.
        let mut once: Option<Statement<'a>> = None;
        for (statement, every) in start {
            if every {
                function.statements.extend(once.take());
                function.statements.push(statement);
                continue;
            }
            let block = once.get_or_insert_with(|| {
                parse("if (!again) {}")
                    .into_iter()
                    .next()
                    .expect("one statement")
            });
            if let Statement::IfStatement(branch) = block {
                if let Statement::BlockStatement(body) = &mut branch.consequent {
                    body.body.push(statement);
                }
            }
        }
        function.statements.extend(once);
    }
    prelude.extend(definers);
    prelude.extend(body);
    program.body = prelude;
}

#[derive(Default)]
struct References(HashSet<String>);

impl<'a> oxc::ast_visit::Visit<'a> for References {
    fn visit_identifier_reference(&mut self, id: &IdentifierReference<'a>) {
        self.0.insert(id.name.to_string());
    }
}

/// The names whose value the module changes in place anywhere — `x.set(…)`,
/// `x.push(…)`, `x[i] = …`, `x.f = …` — so a global bound to one keeps
/// state between triggers.
fn mutated_names(program: &Program<'_>) -> HashSet<String> {
    use oxc::ast_visit::{walk, Visit};

    const MUTATORS: &[&str] = &[
        "set",
        "push",
        "pop",
        "shift",
        "unshift",
        "splice",
        "add",
        "delete",
        "clear",
        "fill",
        "sort",
        "reverse",
        "copyWithin",
    ];
    fn root<'s>(expr: &'s Expression<'_>) -> Option<&'s str> {
        match expr {
            Expression::Identifier(id) => Some(id.name.as_str()),
            Expression::StaticMemberExpression(member) => root(&member.object),
            Expression::ComputedMemberExpression(member) => root(&member.object),
            _ => None,
        }
    }
    #[derive(Default)]
    struct Bound(HashSet<String>);
    impl<'a> Visit<'a> for Bound {
        fn visit_binding_identifier(&mut self, id: &BindingIdentifier<'a>) {
            self.0.insert(id.name.to_string());
        }
    }
    /// What each enclosing function binds itself: a local of the same name
    /// isn't the global.
    #[derive(Default)]
    struct Scan {
        mutated: HashSet<String>,
        locals: Vec<HashSet<String>>,
    }
    impl Scan {
        fn record(&mut self, object: Option<&Expression<'_>>) {
            if let Some(name) = object.and_then(root) {
                if !self.locals.iter().any(|locals| locals.contains(name)) {
                    self.mutated.insert(name.to_string());
                }
            }
        }
    }
    impl<'a> Visit<'a> for Scan {
        fn visit_function(&mut self, func: &Function<'a>, flags: ScopeFlags) {
            let mut bound = Bound::default();
            bound.visit_formal_parameters(&func.params);
            if let Some(body) = &func.body {
                bound.visit_function_body(body);
            }
            self.locals.push(bound.0);
            walk::walk_function(self, func, flags);
            self.locals.pop();
        }
        fn visit_call_expression(&mut self, call: &CallExpression<'a>) {
            if let Expression::StaticMemberExpression(member) = &call.callee {
                if MUTATORS.contains(&member.property.name.as_str()) {
                    self.record(Some(&member.object));
                }
            }
            walk::walk_call_expression(self, call);
        }
        fn visit_assignment_target(&mut self, target: &AssignmentTarget<'a>) {
            let object = match target {
                AssignmentTarget::StaticMemberExpression(member) => Some(&member.object),
                AssignmentTarget::ComputedMemberExpression(member) => Some(&member.object),
                _ => None,
            };
            self.record(object);
            walk::walk_assignment_target(self, target);
        }
        fn visit_update_expression(&mut self, update: &UpdateExpression<'a>) {
            let object = match &update.argument {
                SimpleAssignmentTarget::StaticMemberExpression(member) => Some(&member.object),
                SimpleAssignmentTarget::ComputedMemberExpression(member) => Some(&member.object),
                _ => None,
            };
            self.record(object);
            walk::walk_update_expression(self, update);
        }
    }
    let mut scan = Scan::default();
    scan.visit_program(program);
    scan.mutated
}

/// A literal's source text, to set a static field to it again.
fn literal_text(value: &Expression<'_>) -> Option<String> {
    Some(match value {
        Expression::NumericLiteral(number) => number.value.to_string(),
        Expression::BooleanLiteral(boolean) => boolean.value.to_string(),
        Expression::NullLiteral(_) => "null".to_string(),
        Expression::StringLiteral(text) => serde_json::to_string(text.value.as_str()).ok()?,
        _ => return None,
    })
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
    module_names: ModuleNames,
    /// What each enclosing function's names hold (`Locals`).
    locals: Vec<Locals>,
    /// The type parameters in scope: a `T` field has no zero this pass knows.
    generics: Vec<HashSet<String>>,
    /// Visiting a `for (let x of …)` head, whose binding has no initializer.
    in_for_head: bool,
}

#[derive(Clone, Copy)]
enum Zero {
    Number,
    False,
    Null,
}

/// What AssemblyScript gives a field or local of this type that has no
/// initializer (asc's `makeZero`): 0 for an integer or float, false for a
/// bool, null for a reference.
fn zero_of(ty: &TSType<'_>, generics: &[HashSet<String>]) -> Option<Zero> {
    match ty {
        TSType::TSNumberKeyword(_) => Some(Zero::Number),
        TSType::TSBooleanKeyword(_) => Some(Zero::False),
        TSType::TSStringKeyword(_) | TSType::TSArrayType(_) | TSType::TSTupleType(_) => {
            Some(Zero::Null)
        }
        TSType::TSTypeReference(reference) => match &reference.type_name {
            TSTypeName::IdentifierReference(name) => match name.name.as_str() {
                "i8" | "i16" | "i32" | "i64" | "isize" | "u8" | "u16" | "u32" | "u64" | "usize"
                | "f32" | "f64" => Some(Zero::Number),
                "bool" | "boolean" => Some(Zero::False),
                name if generics.iter().any(|scope| scope.contains(name)) => None,
                _ => Some(Zero::Null),
            },
            _ => Some(Zero::Null),
        },
        TSType::TSUnionType(union) => union
            .types
            .iter()
            .any(|ty| matches!(ty, TSType::TSNullKeyword(_)))
            .then_some(Zero::Null),
        _ => None,
    }
}

fn type_parameter_names(
    parameters: &Option<oxc::allocator::Box<'_, TSTypeParameterDeclaration<'_>>>,
) -> HashSet<String> {
    parameters
        .iter()
        .flat_map(|declaration| declaration.params.iter())
        .map(|parameter| parameter.name.name.to_string())
        .collect()
}

/// What `===` can know of a string without types. AssemblyScript compares two
/// strings' addresses: a literal is one static segment wherever it is written
/// (asc deduplicates them), and a string the host returns is a new allocation
/// every time — graph-node writes it into the module's memory per call.
#[derive(Default)]
struct Locals {
    /// Locals initialized with an `allocates` call and never assigned again.
    fresh: HashSet<String>,
    /// Names that read a literal: the module's literal `const`s this function
    /// doesn't rebind.
    literal: HashSet<String>,
    /// Names declared `u32`: its own parameters and locals, and the module's
    /// globals this function doesn't rebind.
    unsigned: HashSet<String>,
    /// Names declared with an integer type, by the type, likewise.
    integers: HashMap<String, String>,
    /// Class-typed locals declared without a value whose first use writes one
    /// of their fields, by their class.
    null_objects: HashMap<String, String>,
}

/// What the module's top level declares, for every function in it.
#[derive(Default)]
struct ModuleNames {
    /// `const`s bound to a string literal.
    literal_consts: HashSet<String>,
    /// Globals declared `u32`.
    unsigned: HashSet<String>,
    /// Functions declared to return a `u32`.
    unsigned_functions: HashSet<String>,
    /// Globals declared with an integer type, by the type.
    integers: HashMap<String, String>,
    /// Every top-level function's name.
    functions: HashSet<String>,
}

/// The integer type an annotation names, if it names one.
fn integer_annotation(annotation: Option<&TSTypeAnnotation<'_>>) -> Option<String> {
    let TSType::TSTypeReference(reference) = &annotation?.type_annotation else {
        return None;
    };
    let TSTypeName::IdentifierReference(name) = &reference.type_name else {
        return None;
    };
    matches!(
        name.name.as_str(),
        "i8" | "u8" | "i16" | "u16" | "i32" | "u32" | "i64" | "u64" | "isize" | "usize"
    )
    .then(|| name.name.to_string())
}

fn is_u32(annotation: Option<&TSTypeAnnotation<'_>>) -> bool {
    matches!(annotation.map(|annotation| &annotation.type_annotation),
        Some(TSType::TSTypeReference(reference))
            if matches!(&reference.type_name, TSTypeName::IdentifierReference(name) if name.name == "u32"))
}

enum StringKind<'s> {
    /// Allocated by this very expression: identical to nothing else.
    Allocated,
    /// A local holding an allocation of its own, which another local may alias.
    Fresh(&'s str),
    Literal,
    Unknown,
}

/// A call whose string graph-ts gets from the host: `dataSource.network()`,
/// `typeConversion.bytesToHex` behind `toHexString()`.
fn allocates(expr: &Expression<'_>) -> bool {
    let Expression::CallExpression(call) = expr.without_parentheses() else {
        return false;
    };
    if !call.arguments.is_empty() || call.optional {
        return false;
    }
    let Expression::StaticMemberExpression(member) = &call.callee else {
        return false;
    };
    match member.property.name.as_str() {
        "toHexString" | "toHex" | "toBase58" => true,
        "network" | "stringParam" => {
            matches!(&member.object, Expression::Identifier(id) if id.name == "dataSource")
        }
        _ => false,
    }
}

fn is_string_literal(expr: &Expression<'_>) -> bool {
    match expr.without_parentheses() {
        Expression::StringLiteral(_) => true,
        Expression::TemplateLiteral(template) => template.expressions.is_empty(),
        _ => false,
    }
}

impl Locals {
    fn kind<'e>(&self, expr: &'e Expression<'_>) -> StringKind<'e> {
        if allocates(expr) {
            return StringKind::Allocated;
        }
        if is_string_literal(expr) {
            return StringKind::Literal;
        }
        match expr.without_parentheses() {
            Expression::Identifier(id) if self.fresh.contains(id.name.as_str()) => {
                StringKind::Fresh(id.name.as_str())
            }
            Expression::Identifier(id) if self.literal.contains(id.name.as_str()) => {
                StringKind::Literal
            }
            _ => StringKind::Unknown,
        }
    }

    /// Whether `left === right` compares a host allocation with something that
    /// can't be that allocation.
    fn distinct(&self, left: &Expression<'_>, right: &Expression<'_>) -> bool {
        use StringKind::*;
        match (self.kind(left), self.kind(right)) {
            (Allocated, _) | (_, Allocated) => true,
            (Fresh(a), Fresh(b)) => a != b,
            (Fresh(_), Literal) | (Literal, Fresh(_)) => true,
            _ => false,
        }
    }
}

/// What the module's top level declares, for every function in it.
fn module_names(program: &Program<'_>) -> ModuleNames {
    let mut names = ModuleNames::default();
    for statement in &program.body {
        let declaration = match statement {
            Statement::ExportDeclaration(export) => &export.declaration,
            other => match other.as_declaration() {
                Some(declaration) => declaration,
                None => continue,
            },
        };
        match declaration {
            Declaration::VariableDeclaration(decl) => {
                for declarator in &decl.declarations {
                    let BindingPattern::BindingIdentifier(id) = &declarator.id else {
                        continue;
                    };
                    if decl.kind == VariableDeclarationKind::Const
                        && declarator.init.as_ref().is_some_and(is_string_literal)
                    {
                        names.literal_consts.insert(id.name.to_string());
                    }
                    if is_u32(declarator.type_annotation.as_deref()) {
                        names.unsigned.insert(id.name.to_string());
                    }
                    if let Some(ty) = integer_annotation(declarator.type_annotation.as_deref()) {
                        names.integers.insert(id.name.to_string(), ty);
                    }
                }
            }
            Declaration::FunctionDeclaration(func) => {
                if let Some(id) = &func.id {
                    names.functions.insert(id.name.to_string());
                    if is_u32(func.return_type.as_deref()) {
                        names.unsigned_functions.insert(id.name.to_string());
                    }
                }
            }
            _ => {}
        }
    }
    names
}

/// What a function's names hold. A name bound twice anywhere in the function —
/// a parameter, a nested block's own `let` — is left out rather than told apart.
fn locals(func: &Function<'_>, module: &ModuleNames, classes: &HashSet<String>) -> Locals {
    use oxc::ast_visit::{walk, Visit};

    #[derive(Default)]
    struct Scan {
        bound: std::collections::HashMap<String, usize>,
        fresh: HashSet<String>,
        assigned: HashSet<String>,
        unsigned: HashSet<String>,
        integers: HashMap<String, String>,
        /// `let x: C;` of a class C, by name.
        uninitialized: HashMap<String, String>,
    }
    impl<'a> Visit<'a> for Scan {
        fn visit_binding_identifier(&mut self, id: &BindingIdentifier<'a>) {
            *self.bound.entry(id.name.to_string()).or_default() += 1;
        }
        fn visit_formal_parameter(&mut self, param: &FormalParameter<'a>) {
            if let BindingPattern::BindingIdentifier(id) = &param.pattern {
                if is_u32(param.type_annotation.as_deref()) {
                    self.unsigned.insert(id.name.to_string());
                }
                if let Some(ty) = integer_annotation(param.type_annotation.as_deref()) {
                    self.integers.insert(id.name.to_string(), ty);
                }
            }
            walk::walk_formal_parameter(self, param);
        }
        fn visit_variable_declarator(&mut self, declarator: &VariableDeclarator<'a>) {
            if let BindingPattern::BindingIdentifier(id) = &declarator.id {
                if declarator.init.as_ref().is_some_and(allocates) {
                    self.fresh.insert(id.name.to_string());
                }
                if is_u32(declarator.type_annotation.as_deref()) {
                    self.unsigned.insert(id.name.to_string());
                }
                if let Some(ty) = integer_annotation(declarator.type_annotation.as_deref()) {
                    self.integers.insert(id.name.to_string(), ty);
                }
                if declarator.init.is_none() {
                    if let Some(TSType::TSTypeReference(reference)) = declarator
                        .type_annotation
                        .as_deref()
                        .map(|annotation| &annotation.type_annotation)
                    {
                        if let TSTypeName::IdentifierReference(class) = &reference.type_name {
                            self.uninitialized
                                .insert(id.name.to_string(), class.name.to_string());
                        }
                    }
                }
            }
            walk::walk_variable_declarator(self, declarator);
        }
        fn visit_simple_assignment_target(&mut self, target: &SimpleAssignmentTarget<'a>) {
            if let SimpleAssignmentTarget::AssignmentTargetIdentifier(id) = target {
                self.assigned.insert(id.name.to_string());
            }
            walk::walk_simple_assignment_target(self, target);
        }
    }

    let mut scan = Scan::default();
    scan.visit_function(func, ScopeFlags::Function);
    let fresh = scan
        .fresh
        .iter()
        .filter(|name| scan.bound.get(*name) == Some(&1) && !scan.assigned.contains(*name))
        .cloned()
        .collect();
    let module_level = |names: &HashSet<String>| -> HashSet<String> {
        names
            .iter()
            .filter(|name| !scan.bound.contains_key(*name))
            .cloned()
            .collect()
    };
    let literal = module_level(&module.literal_consts);
    let mut unsigned = module_level(&module.unsigned);
    unsigned.extend(
        scan.unsigned
            .iter()
            .filter(|name| scan.bound.get(*name) == Some(&1))
            .cloned(),
    );
    let mut integers: HashMap<String, String> = module
        .integers
        .iter()
        .filter(|(name, _)| !scan.bound.contains_key(*name))
        .map(|(name, ty)| (name.clone(), ty.clone()))
        .collect();
    integers.extend(
        scan.integers
            .into_iter()
            .filter(|(name, _)| scan.bound.get(name) == Some(&1)),
    );

    // Whether each candidate's first use, in source order, writes a field of
    // it (`x.f = …`): the null pointer asc gives it is then an object the
    // function builds in place.
    struct FirstUse<'c> {
        candidates: &'c HashMap<String, String>,
        writes_field: HashMap<String, bool>,
    }
    impl<'a> Visit<'a> for FirstUse<'_> {
        fn visit_assignment_expression(&mut self, assign: &AssignmentExpression<'a>) {
            if let AssignmentTarget::StaticMemberExpression(member) = &assign.left {
                if let Expression::Identifier(id) = &member.object {
                    let name = id.name.as_str();
                    if self.candidates.contains_key(name) && !self.writes_field.contains_key(name) {
                        self.writes_field.insert(name.to_string(), true);
                    }
                }
            }
            walk::walk_assignment_expression(self, assign);
        }
        fn visit_identifier_reference(&mut self, id: &IdentifierReference<'a>) {
            let name = id.name.as_str();
            if self.candidates.contains_key(name) && !self.writes_field.contains_key(name) {
                self.writes_field.insert(name.to_string(), false);
            }
        }
    }
    let candidates: HashMap<String, String> = scan
        .uninitialized
        .into_iter()
        .filter(|(name, class)| scan.bound.get(name) == Some(&1) && classes.contains(class))
        .collect();
    let mut first_use = FirstUse {
        candidates: &candidates,
        writes_field: HashMap::new(),
    };
    first_use.visit_function(func, ScopeFlags::Function);
    let null_objects = candidates
        .iter()
        .filter(|(name, _)| first_use.writes_field.get(*name) == Some(&true))
        .map(|(name, class)| (name.clone(), class.clone()))
        .collect();
    Locals {
        fresh,
        literal,
        unsigned,
        integers,
        null_objects,
    }
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
        BinaryOperator::BitwiseAnd => "band",
        BinaryOperator::BitwiseOR => "bor",
        BinaryOperator::BitwiseXOR => "bxor",
        BinaryOperator::ShiftLeft => "shl",
        BinaryOperator::ShiftRight => "shr",
        BinaryOperator::ShiftRightZeroFill => "ushr",
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

/// The `OPERATORS_HELPER` method for a bit operation on a `u32`, whose
/// result AssemblyScript keeps unsigned where JavaScript's is an int32.
fn unsigned_helper(operator: BinaryOperator) -> Option<&'static str> {
    Some(match operator {
        BinaryOperator::ShiftLeft => "shl_u32",
        BinaryOperator::ShiftRight => "shr_u32",
        BinaryOperator::BitwiseOR => "or_u32",
        BinaryOperator::BitwiseAnd => "and_u32",
        BinaryOperator::BitwiseXOR => "xor_u32",
        _ => return None,
    })
}

fn unsigned_assignment_helper(operator: AssignmentOperator) -> Option<&'static str> {
    Some(match operator {
        AssignmentOperator::ShiftLeft => "shl_u32",
        AssignmentOperator::ShiftRight => "shr_u32",
        AssignmentOperator::BitwiseOR => "or_u32",
        AssignmentOperator::BitwiseAnd => "and_u32",
        AssignmentOperator::BitwiseXOR => "xor_u32",
        _ => return None,
    })
}

fn is_shift(operator: BinaryOperator) -> bool {
    matches!(
        operator,
        BinaryOperator::ShiftLeft | BinaryOperator::ShiftRight
    )
}

fn assignment_helper(operator: AssignmentOperator) -> Option<&'static str> {
    Some(match operator {
        AssignmentOperator::Addition => "add",
        AssignmentOperator::Subtraction => "sub",
        AssignmentOperator::Multiplication => "mul",
        AssignmentOperator::Division => "div",
        AssignmentOperator::Remainder => "rem",
        AssignmentOperator::Exponential => "pow",
        AssignmentOperator::BitwiseAnd => "band",
        AssignmentOperator::BitwiseOR => "bor",
        AssignmentOperator::BitwiseXOR => "bxor",
        AssignmentOperator::ShiftLeft => "shl",
        AssignmentOperator::ShiftRight => "shr",
        AssignmentOperator::ShiftRightZeroFill => "ushr",
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

    /// `load<T>(p)`, `store<T>(p, v)`, `reinterpret<T>(x)`, `bswap(x)`,
    /// `rotr(x, n)`, `rotl(x, n)`: AssemblyScript builtins of a type, which the
    /// call names or its operand has. The helper method and its arguments, the
    /// type as a string — for `load`, `store` and `reinterpret` first, after the
    /// operands for the others.
    fn memory_builtin(
        &self,
        call: &mut CallExpression<'a>,
    ) -> Option<(&'static str, Vec<Expression<'a>>)> {
        let Expression::Identifier(callee) = &call.callee else {
            return None;
        };
        let method = match callee.name.as_str() {
            "load" => "load",
            "store" => "store",
            "reinterpret" => "reinterpret",
            "bswap" => "bswap",
            "rotl" => "rotl",
            "rotr" => "rotr",
            _ => return None,
        };
        if self.classes.contains(callee.name.as_str())
            || self.module_names.functions.contains(callee.name.as_str())
        {
            return None;
        }
        let named = call
            .type_arguments
            .as_ref()
            .and_then(|arguments| arguments.params.first())
            .and_then(|ty| match ty {
                TSType::TSTypeReference(reference) => match &reference.type_name {
                    TSTypeName::IdentifierReference(name) => Some(name.name.to_string()),
                    _ => None,
                },
                TSType::TSBooleanKeyword(_) => Some("bool".to_string()),
                _ => None,
            });
        let typed_first = matches!(method, "load" | "store" | "reinterpret");
        if typed_first && named.is_none() {
            return None;
        }
        let ty = named.or_else(|| {
            call.arguments
                .first()
                .and_then(|argument| argument.as_expression())
                .and_then(|operand| self.integer_type(operand))
        });
        let text: &'a str = self.ast.allocator().alloc_str(ty.as_deref().unwrap_or(""));
        let ty = Expression::new_string_literal(call.span, text, None, &self.ast);
        let mut args: Vec<Expression<'a>> = call
            .arguments
            .iter_mut()
            .map(|argument| argument.to_expression_mut().take_in(&self.ast))
            .collect();
        if typed_first {
            args.insert(0, ty);
        } else {
            while args.len() < if method == "bswap" { 1 } else { 2 } {
                args.push(Expression::new_numeric_literal(
                    call.span,
                    0.0,
                    None,
                    oxc::syntax::number::NumberBase::Decimal,
                    &self.ast,
                ));
            }
            args.push(ty);
        }
        Some((method, args))
    }

    /// The integer type an operand has, as far as this pass can tell.
    fn integer_type(&self, expr: &Expression<'a>) -> Option<String> {
        match expr.without_parentheses() {
            Expression::Identifier(id) => {
                let name = id.name.as_str();
                let declared = match self.locals.last() {
                    Some(locals) => locals.integers.get(name),
                    None => self.module_names.integers.get(name),
                };
                declared.cloned()
            }
            Expression::CallExpression(call) => match &call.callee {
                Expression::StaticMemberExpression(member) => {
                    let name = member.property.name.as_str();
                    let helper = matches!(&member.object, Expression::Identifier(id) if id.name == OPERATORS_HELPER);
                    if helper && matches!(name, "load" | "bswap" | "rotl" | "rotr") {
                        let index = if name == "load" {
                            0
                        } else {
                            call.arguments.len().saturating_sub(1)
                        };
                        match call.arguments.get(index)?.as_expression()? {
                            Expression::StringLiteral(ty) if !ty.value.is_empty() => {
                                Some(ty.value.to_string())
                            }
                            _ => None,
                        }
                    } else if helper && name.starts_with("as_") {
                        Some(name.trim_start_matches("as_").to_string())
                    } else if helper && name.ends_with("_u32") {
                        Some("u32".to_string())
                    } else {
                        match name {
                            "toU32" => Some("u32".to_string()),
                            "toI32" => Some("i32".to_string()),
                            "toU64" => Some("u64".to_string()),
                            "toI64" => Some("i64".to_string()),
                            _ => None,
                        }
                    }
                }
                _ => None,
            },
            _ => None,
        }
    }

    fn unsigned_name(&self, name: &str) -> bool {
        match self.locals.last() {
            Some(locals) => locals.unsigned.contains(name),
            None => self.module_names.unsigned.contains(name),
        }
    }

    /// An expression whose AssemblyScript type is `u32`, as far as its names
    /// and graph-ts' signatures say: a name declared so, `x.toU32()`,
    /// `x as u32`, a call of a function returning one, a bit operation on one.
    fn unsigned(&self, expr: &Expression<'a>) -> bool {
        match expr.without_parentheses() {
            Expression::Identifier(id) => self.unsigned_name(id.name.as_str()),
            Expression::CallExpression(call) => match &call.callee {
                Expression::StaticMemberExpression(member) => {
                    let name = member.property.name.as_str();
                    (name == "toU32" && call.arguments.is_empty())
                        || (matches!(&member.object, Expression::Identifier(id) if id.name == OPERATORS_HELPER)
                            && (name == "as_u32" || name.ends_with("_u32")))
                }
                Expression::Identifier(callee) => self
                    .module_names
                    .unsigned_functions
                    .contains(callee.name.as_str()),
                _ => false,
            },
            _ => false,
        }
    }

    fn zero(&self, span: Span, annotation: &TSTypeAnnotation<'a>) -> Option<Expression<'a>> {
        Some(
            match zero_of(&annotation.type_annotation, &self.generics)? {
                Zero::Number => Expression::new_numeric_literal(
                    span,
                    0.0,
                    None,
                    oxc::syntax::number::NumberBase::Decimal,
                    &self.ast,
                ),
                Zero::False => Expression::new_boolean_literal(span, false, &self.ast),
                Zero::Null => Expression::new_null_literal(span, &self.ast),
            },
        )
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
    /// A cast to `ty`, which `expression` is taken from when it converts.
    ///
    /// To a number type it converts: a wider integer wraps, a float truncates
    /// toward zero, null is 0, and a reference is its address, which JavaScript
    /// has no number for; to a float, an i64 (a bigint here) is a float. To a
    /// class — graph-cli before 0.2x's tuple getters and old entity loads cast
    /// so, not with `changetype` — it is the same reinterpret, except that a
    /// value already of the class (an upcast) keeps its own.
    fn cast(
        &self,
        span: Span,
        ty: &TSType<'a>,
        expression: &mut Expression<'a>,
    ) -> Option<Expression<'a>> {
        let number = match ty {
            TSType::TSTypeReference(reference) => match &reference.type_name {
                TSTypeName::IdentifierReference(ty) => match ty.name.as_str() {
                    "i8" => Some("as_i8"),
                    "u8" => Some("as_u8"),
                    "i16" => Some("as_i16"),
                    "u16" => Some("as_u16"),
                    "i32" => Some("as_i32"),
                    "u32" => Some("as_u32"),
                    "f32" => Some("as_f32"),
                    "f64" => Some("as_f64"),
                    _ => None,
                },
                _ => None,
            },
            _ => None,
        };
        if let Some(method) = number {
            let value = expression.take_in(&self.ast);
            return Some(self.operator(span, method, [value]));
        }
        let class = match ty {
            TSType::TSUnionType(union) => union
                .types
                .iter()
                .find_map(|ty| class_ref(ty, &self.classes)),
            ty => class_ref(ty, &self.classes),
        }?;
        let ctor = Expression::new_identifier(
            class.span,
            Ident::from_str_in(class.name.as_str(), &self.ast),
            &self.ast,
        );
        let value = expression.take_in(&self.ast);
        let keep = Expression::new_boolean_literal(span, true, &self.ast);
        Some(self.call(span, RETAG_HELPER, [ctor, value, keep]))
    }

    fn retag_target(&self, call: &CallExpression<'a>) -> Option<(Span, String)> {
        let Expression::Identifier(callee) = &call.callee else {
            return None;
        };
        if callee.name != "changetype" || call.arguments.len() != 1 {
            return None;
        }
        // `changetype<Pair | null>(store.get(...))` is how generated code
        // loads an entity: the class's getters are what reads its fields.
        let class = match call.type_arguments.as_ref()?.params.first()? {
            TSType::TSUnionType(union) => union
                .types
                .iter()
                .find_map(|ty| class_ref(ty, &self.classes)),
            ty => class_ref(ty, &self.classes),
        }?;
        Some((class.span, class.name.to_string()))
    }
}

/// `changetype<usize>(ref)`: a reference reinterpreted as an integer is its
/// address — what a mapping compares with 0 to test for null.
fn integer_changetype(call: &CallExpression<'_>) -> bool {
    let Expression::Identifier(callee) = &call.callee else {
        return false;
    };
    if callee.name != "changetype" || call.arguments.len() != 1 {
        return false;
    }
    let Some(TSType::TSTypeReference(reference)) = call
        .type_arguments
        .as_ref()
        .and_then(|arguments| arguments.params.first())
    else {
        return false;
    };
    matches!(&reference.type_name, TSTypeName::IdentifierReference(ty) if matches!(
        ty.name.as_str(),
        "usize" | "isize" | "u64" | "i64" | "u32" | "i32" | "u16" | "i16" | "u8" | "i8"
    ))
}

/// The element type of `new StaticArray<T>(n)` when a typed array holds it:
/// a number type up to 32 bits, or a float.
fn static_array_element(new: &NewExpression<'_>) -> Option<&'static str> {
    let TSType::TSTypeReference(reference) = new.type_arguments.as_ref()?.params.first()? else {
        return None;
    };
    let TSTypeName::IdentifierReference(name) = &reference.type_name else {
        return None;
    };
    Some(match name.name.as_str() {
        "i8" => "i8",
        "u8" => "u8",
        "i16" => "i16",
        "u16" => "u16",
        "i32" | "isize" => "i32",
        "u32" | "usize" => "u32",
        "f32" => "f32",
        "f64" => "f64",
        _ => return None,
    })
}

fn is_pure(expr: &Expression<'_>) -> bool {
    match expr {
        Expression::Identifier(_) | Expression::ThisExpression(_) => true,
        Expression::StaticMemberExpression(member) => is_pure(&member.object),
        // `account!.count += 1`: an assertion or a cast reads the same twice.
        Expression::TSNonNullExpression(inner) => is_pure(&inner.expression),
        Expression::TSAsExpression(cast) => is_pure(&cast.expression),
        Expression::ParenthesizedExpression(paren) => is_pure(&paren.expression),
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
            Expression::BinaryExpression(binary)
                if matches!(
                    binary.operator,
                    BinaryOperator::StrictEquality | BinaryOperator::StrictInequality
                ) =>
            {
                let distinct = match self.locals.last() {
                    Some(strings) => strings.distinct(&binary.left, &binary.right),
                    None => allocates(&binary.left) || allocates(&binary.right),
                };
                let method = if distinct { "same_fresh" } else { "same" };
                let span = binary.span;
                let negate = binary.operator == BinaryOperator::StrictInequality;
                let left = binary.left.take_in(&self.ast);
                let right = binary.right.take_in(&self.ast);
                let same = self.operator(span, method, [left, right]);
                *expr = if negate {
                    Expression::new_unary_expression(
                        span,
                        UnaryOperator::LogicalNot,
                        same,
                        &self.ast,
                    )
                } else {
                    same
                };
            }
            Expression::BinaryExpression(binary)
                if unsigned_helper(binary.operator).is_some_and(|_| {
                    self.unsigned(&binary.left)
                        || (!is_shift(binary.operator) && self.unsigned(&binary.right))
                }) =>
            {
                let method = unsigned_helper(binary.operator).expect("checked");
                let span = binary.span;
                let left = binary.left.take_in(&self.ast);
                let right = binary.right.take_in(&self.ast);
                *expr = self.operator(span, method, [left, right]);
            }
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
            Expression::AssignmentExpression(assign)
                if unsigned_assignment_helper(assign.operator).is_some()
                    && matches!(&assign.left, AssignmentTarget::AssignmentTargetIdentifier(id)
                        if self.unsigned_name(id.name.as_str())) =>
            {
                let method = unsigned_assignment_helper(assign.operator).expect("checked");
                let read = self
                    .read_of(&assign.left)
                    .expect("an identifier reads again");
                let right = assign.right.take_in(&self.ast);
                assign.right = self.operator(assign.span, method, [read, right]);
                assign.operator = AssignmentOperator::Assign;
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
            // `x as T` and `<T>x` are one cast in AssemblyScript.
            Expression::TSAsExpression(cast) => {
                let TSAsExpression {
                    span,
                    expression,
                    type_annotation,
                    ..
                } = &mut **cast;
                if let Some(cast) = self.cast(*span, type_annotation, expression) {
                    *expr = cast;
                }
            }
            Expression::TSTypeAssertion(cast) => {
                let TSTypeAssertion {
                    span,
                    expression,
                    type_annotation,
                    ..
                } = &mut **cast;
                if let Some(cast) = self.cast(*span, type_annotation, expression) {
                    *expr = cast;
                }
            }
            // AssemblyScript's std Map and Set aren't JavaScript's: `keys()`
            // is an array and `map[key]` an operator (std/assembly/map.ts).
            // `new StaticArray<u32>(n)` holds u32s: a store wraps, as a typed
            // array's does, and the elements start at zero.
            Expression::NewExpression(new)
                if matches!(&new.callee, Expression::Identifier(callee)
                    if callee.name == "StaticArray" && !self.classes.contains("StaticArray"))
                    && static_array_element(new).is_some()
                    && new.arguments.len() == 1 =>
            {
                let element = static_array_element(new).expect("checked");
                let span = new.span;
                let text: &'a str = self.ast.allocator().alloc_str(element);
                let element = Expression::new_string_literal(span, text, None, &self.ast);
                let length = new.arguments[0].to_expression_mut().take_in(&self.ast);
                *expr = self.operator(span, "static_array", [element, length]);
            }
            Expression::NewExpression(new) => {
                let Expression::Identifier(callee) = &mut new.callee else {
                    return;
                };
                let builtin = match callee.name.as_str() {
                    "Map" => AS_MAP,
                    "Set" => AS_SET,
                    _ => return,
                };
                if !self.classes.contains(callee.name.as_str()) {
                    callee.name = Ident::from_str_in(builtin, &self.ast);
                }
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
                if let Some((method, args)) = self.memory_builtin(call) {
                    let span = call.span;
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
                if integer_changetype(call) {
                    let span = call.span;
                    let value = call.arguments[0].to_expression_mut().take_in(&self.ast);
                    *expr = self.operator(span, "address", [value]);
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

    fn visit_class(&mut self, class: &mut Class<'a>) {
        self.generics
            .push(type_parameter_names(&class.type_parameters));
        walk_mut::walk_class(self, class);
        self.generics.pop();
    }

    fn visit_property_definition(&mut self, property: &mut PropertyDefinition<'a>) {
        walk_mut::walk_property_definition(self, property);
        if property.value.is_none()
            && !property.declare
            && property.r#type == PropertyDefinitionType::PropertyDefinition
        {
            if let Some(annotation) = &property.type_annotation {
                property.value = self.zero(property.span, annotation);
            }
        }
    }

    fn visit_for_in_statement(&mut self, statement: &mut ForInStatement<'a>) {
        self.in_for_head = true;
        self.visit_for_statement_left(&mut statement.left);
        self.in_for_head = false;
        self.visit_expression(&mut statement.right);
        self.visit_statement(&mut statement.body);
    }

    fn visit_for_of_statement(&mut self, statement: &mut ForOfStatement<'a>) {
        self.in_for_head = true;
        self.visit_for_statement_left(&mut statement.left);
        self.in_for_head = false;
        self.visit_expression(&mut statement.right);
        self.visit_statement(&mut statement.body);
    }

    fn visit_variable_declaration(&mut self, decl: &mut VariableDeclaration<'a>) {
        walk_mut::walk_variable_declaration(self, decl);
        if self.in_for_head || decl.declare || decl.kind == VariableDeclarationKind::Const {
            return;
        }
        for declarator in decl.declarations.iter_mut() {
            let BindingPattern::BindingIdentifier(id) = &declarator.id else {
                continue;
            };
            if declarator.init.is_some() {
                continue;
            }
            // asc gives it the null pointer, and the function's field writes
            // land at that address: an object every such local of the class
            // shares, as they share address 0 under asc.
            let class = self
                .locals
                .last()
                .and_then(|locals| locals.null_objects.get(id.name.as_str()))
                .cloned();
            if let Some(class) = class {
                let span = declarator.span;
                let class = Expression::new_identifier(
                    span,
                    Ident::from_str_in(&class, &self.ast),
                    &self.ast,
                );
                declarator.init = Some(self.operator(span, "null_object", [class]));
                continue;
            }
            if let Some(annotation) = &declarator.type_annotation {
                declarator.init = self.zero(declarator.span, annotation);
            }
        }
    }

    fn visit_function(&mut self, func: &mut Function<'a>, flags: ScopeFlags) {
        self.generics
            .push(type_parameter_names(&func.type_parameters));
        self.locals
            .push(locals(func, &self.module_names, &self.classes));
        walk_mut::walk_function(self, func, flags);
        self.locals.pop();
        self.generics.pop();
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

    fn transformed(source: &str, legacy_nulls: bool, hoist: bool) -> String {
        let out = transform(source, Path::new("src/mapping.ts"), legacy_nulls, hoist)
            .expect("a readable mapping");
        out.split("//# sourceMappingURL=")
            .next()
            .unwrap()
            .to_string()
    }

    // Each rewrite on its own; `hoisted` adds what `hoist_statics` does.
    fn js(source: &str) -> String {
        transformed(source, false, false)
    }

    fn legacy_js(source: &str) -> String {
        transformed(source, true, false)
    }

    fn hoisted(source: &str) -> String {
        transformed(source, false, true)
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

    // Classes and constant globals once, before anything else; every other
    // top-level statement in the start function, where what keeps state runs
    // again per trigger, after the modules it imports. A class whose
    // definition runs code is defined there, a hoisted class's static field
    // reset there.
    #[test]
    fn splits_a_module_into_static_and_per_trigger_stages() {
        assert_eq!(
            hoisted(
                "import { BigInt } from \"@graphprotocol/graph-ts\";
import { Token } from \"./token\";
export const ethAddress = \"0xEee\";
const LIMIT: i32 = 10 * 6;
export let total: i32 = 0;
const ZERO = BigInt.fromI32(0);
const seen = new Map<string, bool>();
export class Mapping {
  bidwall: string;
  static count: i32;
}
class Registry {
  static instance: Registry = new Registry();
}
seen.set(\"a\", true);
export function f(): Token { return new Token(); }
export * from \"./base\";"
            ),
            "export var ethAddress;
var LIMIT;
export var total;
var ZERO;
var seen;
export var Mapping;
var Registry;
var __envio_static_state;
export function __envio_static() {
\tif (__envio_static_state) return;
\t__envio_static_state = 1;
\t__envio_dep_0.__envio_static?.();
\t__envio_dep_1.__envio_static?.();
\tethAddress = \"0xEee\";
\tLIMIT = __envio_op.mul(10, 6);
\ttotal = 0;
\tZERO = BigInt.fromI32(0);
\ttry {
\t\t__envio_define_Mapping();
\t} catch {}
}
function __envio_start(again) {
\ttotal = 0;
\tseen = new __envio_Map();
\tif (!again) {
\t\t__envio_define_Mapping();
\t}
\tMapping.count = 0;
\tif (!again) {
\t\tRegistry = class Registry {
\t\t\tstatic instance = new Registry();
\t\t};
\t}
\tseen.set(\"a\", true);
}
var __envio_init_generation;
export function __envio_init(generation) {
\tif (__envio_init_generation === generation) return;
\t__envio_init_generation = generation;
\t__envio_dep_0.__envio_init?.(generation);
\t__envio_dep_1.__envio_init?.(generation);
\t__envio_start(true);
}
__envio_static();
try {
\t__envio_start(false);
} catch {}
function __envio_define_Mapping() {
\tif (Mapping === undefined) Mapping = class Mapping {
\t\tbidwall = null;
\t\tstatic count = 0;
\t};
}
import { BigInt } from \"@graphprotocol/graph-ts\";
import { Token } from \"./token\";
import * as __envio_dep_0 from \"./token\";
export function f() {
\treturn new Token();
}
export * from \"./base\";
import * as __envio_dep_1 from \"./base\";
"
        );
    }

    #[test]
    fn zero_initializes_fields_and_locals_by_type() {
        assert_eq!(
            js("class Totals<T> {
  count: i32;
  flag: bool;
  label: string | null;
  value: T;
  static instances: u64;
  declare ambient: i32;
}
export function f(xs: i32[]): i32 {
  let total: i32;
  let owner: Address;
  let untyped;
  for (let x: i32 of xs) {
    total += x;
  }
  return total;
}"),
            "class Totals {
\tcount = 0;
\tflag = false;
\tlabel = null;
\tvalue;
\tstatic instances = 0;
}
export function f(xs) {
\tlet total = 0;
\tlet owner = null;
\tlet untyped;
\tfor (let x of xs) {
\t\ttotal = __envio_op.add(total, x);
\t}
\treturn total;
}
"
        );
    }

    // Only a local whose first use writes one of its fields is built in place:
    // one read first, or assigned first, keeps the null asc gives it.
    #[test]
    fn builds_a_class_local_declared_without_a_value_in_place() {
        assert_eq!(
            js("class Result {
  error: string;
}
export function f(ok: bool): Result {
  let result: Result;
  result.error = ok ? \"none\" : \"failed\";
  let read: Result;
  let isNull = read == null;
  let later: Result;
  later = result;
  return result;
}"),
            "class Result {
\terror = null;
}
export function f(ok) {
\tlet result = __envio_op.null_object(Result);
\tresult.error = ok ? \"none\" : \"failed\";
\tlet read = null;
\tlet isNull = __envio_op.eq(read, null);
\tlet later = null;
\tlater = result;
\treturn result;
}
"
        );
    }

    // An i32's bit operations are JavaScript's own, through the helper that
    // widens an i64 operand.
    #[test]
    fn keeps_a_u32_unsigned_through_bit_operations() {
        assert_eq!(
            js("function word(b: u8[]): u32 {
  return ((b[0] as u32) << 24) | (b[1] as u32);
}
export function f(tick: BigInt, signed: i32): void {
  let mask: u32 = 0xff;
  let id = (tick.toU32() << 8) >> 8;
  let low = word([]) & mask;
  mask >>= 1;
  let plain = signed >> 4;
}"),
            "function word(b) {
\treturn __envio_op.or_u32(__envio_op.shl_u32(__envio_op.as_u32(b[0]), 24), __envio_op.as_u32(b[1]));
}
export function f(tick, signed) {
\tlet mask = 255;
\tlet id = __envio_op.shr_u32(__envio_op.shl_u32(tick.toU32(), 8), 8);
\tlet low = __envio_op.and_u32(word([]), mask);
\tmask = __envio_op.shr_u32(mask, 1);
\tlet plain = __envio_op.shr(signed, 4);
}
"
        );
    }

    // A `load`/`store` the module binds itself (graph-ts' `store`) is its own.
    #[test]
    fn names_the_type_of_a_memory_builtin() {
        assert_eq!(
            js("export function f(x: Uint8Array, u: u64, v: u32): void {
  let w = bswap(load<u32>(changetype<usize>(x.buffer) + 4));
  store<u64>(x.dataStart, bswap(u));
  let r = rotr(v, 7);
  let words = new StaticArray<u32>(16);
  let names = new StaticArray<string>(2);
  let d = reinterpret<f64>(u);
}"),
            "export function f(x, u, v) {
\tlet w = __envio_op.bswap(__envio_op.load(\"u32\", __envio_op.add(__envio_op.address(x.buffer), 4)), \"u32\");
\t__envio_op.store(\"u64\", x.dataStart, __envio_op.bswap(u, \"u64\"));
\tlet r = __envio_op.rotr(v, 7, \"u32\");
\tlet words = __envio_op.static_array(\"u32\", 16);
\tlet names = new StaticArray(2);
\tlet d = __envio_op.reinterpret(\"f64\", u);
}
"
        );
    }

    // A mapping's own `Map` class, imported or declared, is left alone.
    #[test]
    fn builds_assemblyscript_maps_and_sets() {
        assert_eq!(
            js("import { Map as Dict } from \"./dict\";
export function f(): void {
  let totals = new Map<string, i32>();
  let seen = new Set<string>();
  let own = new Dict();
}"),
            "import { Map as Dict } from \"./dict\";
export function f() {
\tlet totals = new __envio_Map();
\tlet seen = new __envio_Set();
\tlet own = new Dict();
}
"
        );
    }

    #[test]
    fn marks_a_host_string_in_a_strict_comparison() {
        assert_eq!(
            js("const MAINNET = 'mainnet';
export function f(action: string, a: Address): bool {
  let network = dataSource.network();
  let other = network;
  return dataSource.network() === 'mainnet' || network !== MAINNET
    || a.toHexString() === ZERO || action === 'add' || network === network || other === network
    || UNKNOWN === network;
}"),
            "const MAINNET = \"mainnet\";
export function f(action, a) {
\tlet network = dataSource.network();
\tlet other = network;
\treturn __envio_op.same_fresh(dataSource.network(), \"mainnet\") || !__envio_op.same_fresh(network, MAINNET) || __envio_op.same_fresh(a.toHexString(), ZERO) || __envio_op.same(action, \"add\") || __envio_op.same(network, network) || __envio_op.same(other, network) || __envio_op.same(UNKNOWN, network);
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
export const __envio_event_classes = { get handleFarmed() {
\treturn Farmed;
} };
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

    // Messari-style mappings count with `account!.depositCount += 1`: a `!` (or
    // a cast, or parentheses) on the object reads the same twice.
    #[test]
    fn applies_a_compound_assignment_through_a_non_null_assertion() {
        assert_eq!(
            js(
                "export function f(account: Account | null, pool: Pool): void {
  account!.depositCount += 1;
  (pool as Pool).total -= 2;
}"
            ),
            "export function f(account, pool) {
\taccount.depositCount = __envio_op.add(account.depositCount, 1);
\tpool.total = __envio_op.sub(pool.total, 2);
}
"
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
\tw[i] = __envio_op.add(w[i], w[__envio_op.band(__envio_op.add(i, 9), 15)]);
\tw[__envio_op.band(__envio_op.add(i, 1), 15)] = __envio_op.bxor(w[__envio_op.band(__envio_op.add(i, 1), 15)], 3);
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
  let old = <Pair>value;
  let byte = <u8>n;
  let float = n as f64;
}"),
            "import { Pair } from \"../generated/schema\";
export function f(value, n) {
\tlet pair = __envio_retag(Pair, value, true);
\tlet maybe = __envio_retag(Pair, value, true);
\tlet wide = __envio_op.as_i32(n);
\tlet old = __envio_retag(Pair, value, true);
\tlet byte = __envio_op.as_u8(n);
\tlet float = __envio_op.as_f64(n);
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
  let loaded = changetype<Pair | null>(store.get(\"Pair\", \"1\"));
  let wide = changetype<i32>(n);
}"),
            "import { Pair } from \"../generated/schema\";
export function f(value, n) {
\tlet pair = __envio_retag(Pair, value);
\tlet loaded = __envio_retag(Pair, store.get(\"Pair\", \"1\"));
\tlet wide = __envio_op.address(n);
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
\tget handleTransfer() {
\t\treturn Transfer;
\t},
\tget handleApproval() {
\t\treturn Approval;
\t}
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
    return amount;
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
