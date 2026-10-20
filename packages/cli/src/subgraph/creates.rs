//! Which of a mapping's handlers can reach `DataSourceTemplate.create`.
//!
//! The register pass reruns a handler at fetch time, against a store that reads
//! null, only to collect the templates it creates. A handler that can't create
//! one gains nothing from it and still pays for every contract call it makes on
//! the way — a pool's swap handler would replay its whole mapping per event. So
//! the pass is kept for the handlers whose code can reach a create.
//!
//! The analysis follows the mapping's module graph from the handler: top-level
//! functions, classes and variables, through relative imports and re-exports,
//! into `generated/templates.ts`, whose classes call `DataSourceTemplate.create`.
//! Everything it can't see is assumed to create: a file that doesn't parse or
//! resolve, a package other than graph-ts, a namespace import of graph-ts. A
//! wrong "creates" costs a register pass; a wrong "doesn't" would lose every
//! address the handler registers.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};

use oxc::{allocator::Allocator, ast::ast::*, ast_visit::Visit, parser::Parser, span::SourceType};

const GRAPH_TS: &str = "@graphprotocol/graph-ts";

#[derive(Debug, Clone)]
enum Imported {
    Name(String),
    Namespace,
}

#[derive(Debug, Default)]
struct Module {
    /// Each top-level declaration and the names its code references.
    decls: HashMap<String, HashSet<String>>,
    imports: HashMap<String, (String, Imported)>,
    /// Exported name -> the local binding it exports.
    exports: HashMap<String, String>,
    reexports: HashMap<String, (String, Imported)>,
    star_reexports: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum Node {
    Decl(PathBuf, String),
    Module(PathBuf),
    Creates,
}

#[derive(Default)]
struct References(HashSet<String>);

impl<'a> Visit<'a> for References {
    fn visit_identifier_reference(&mut self, it: &IdentifierReference<'a>) {
        self.0.insert(it.name.to_string());
    }
}

#[derive(Default)]
struct Bindings(Vec<String>);

impl<'a> Visit<'a> for Bindings {
    fn visit_binding_identifier(&mut self, it: &BindingIdentifier<'a>) {
        self.0.push(it.name.to_string());
    }
    // Only the names a declaration binds at top level: a function's parameters
    // and locals are its own.
    fn visit_function(&mut self, it: &Function<'a>, _flags: oxc::syntax::scope::ScopeFlags) {
        if let Some(id) = &it.id {
            self.visit_binding_identifier(id);
        }
    }
    fn visit_class(&mut self, it: &Class<'a>) {
        if let Some(id) = &it.id {
            self.visit_binding_identifier(id);
        }
    }
    fn visit_expression(&mut self, _it: &Expression<'a>) {}
    fn visit_ts_type_annotation(&mut self, _it: &TSTypeAnnotation<'a>) {}
    fn visit_ts_namespace_declaration(&mut self, it: &TSNamespaceDeclaration<'a>) {
        self.visit_binding_identifier(&it.id);
    }
    fn visit_ts_enum_declaration(&mut self, it: &TSEnumDeclaration<'a>) {
        self.visit_binding_identifier(&it.id);
    }
    fn visit_ts_type_alias_declaration(&mut self, it: &TSTypeAliasDeclaration<'a>) {
        self.visit_binding_identifier(&it.id);
    }
    fn visit_ts_interface_declaration(&mut self, it: &TSInterfaceDeclaration<'a>) {
        self.visit_binding_identifier(&it.id);
    }
}

fn declare(module: &mut Module, declaration: &Declaration<'_>) -> Vec<String> {
    let mut bindings = Bindings::default();
    bindings.visit_declaration(declaration);
    let mut references = References::default();
    references.visit_declaration(declaration);
    for name in &bindings.0 {
        module
            .decls
            .entry(name.clone())
            .or_default()
            .extend(references.0.iter().cloned());
    }
    bindings.0
}

fn imported(name: &ModuleExportName<'_>) -> Imported {
    Imported::Name(name.name().to_string())
}

fn parse(source: &str) -> Option<Module> {
    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, source, SourceType::ts()).parse();
    if parsed.panicked || parsed.diagnostics.has_errors() {
        return None;
    }
    let mut module = Module::default();
    for statement in &parsed.program.body {
        if let Some(declaration) = statement.as_declaration() {
            declare(&mut module, declaration);
            continue;
        }
        let Some(declaration) = statement.as_module_declaration() else {
            continue;
        };
        match declaration {
            ModuleDeclaration::ImportDeclaration(import) => {
                let source = import.source.value.to_string();
                for specifier in import.specifiers.iter().flatten() {
                    let (local, what) = match specifier {
                        ImportDeclarationSpecifier::ImportSpecifier(s) => {
                            (s.local.name.to_string(), imported(&s.imported))
                        }
                        ImportDeclarationSpecifier::ImportDefaultSpecifier(s) => {
                            (s.local.name.to_string(), Imported::Name("default".into()))
                        }
                        ImportDeclarationSpecifier::ImportNamespaceSpecifier(s) => {
                            (s.local.name.to_string(), Imported::Namespace)
                        }
                    };
                    module.imports.insert(local, (source.clone(), what));
                }
            }
            ModuleDeclaration::ExportDeclaration(export) => {
                for name in declare(&mut module, &export.declaration) {
                    module.exports.insert(name.clone(), name);
                }
            }
            ModuleDeclaration::ExportNamedDeclaration(export) => {
                for specifier in &export.specifiers {
                    module.exports.insert(
                        specifier.exported.name().to_string(),
                        specifier.local.name().to_string(),
                    );
                }
            }
            ModuleDeclaration::ExportFromDeclaration(export) => {
                let source = export.source.value.to_string();
                for specifier in &export.specifiers {
                    module.reexports.insert(
                        specifier.exported.name().to_string(),
                        (source.clone(), imported(&specifier.local)),
                    );
                }
            }
            ModuleDeclaration::ExportAllDeclaration(export) => {
                let source = export.source.value.to_string();
                match &export.exported {
                    Some(name) => {
                        module
                            .reexports
                            .insert(name.name().to_string(), (source, Imported::Namespace));
                    }
                    None => module.star_reexports.push(source),
                }
            }
            ModuleDeclaration::ExportDefaultDeclaration(export) => {
                let mut references = References::default();
                references.visit_export_default_declaration(export);
                module
                    .decls
                    .entry("default".into())
                    .or_default()
                    .extend(references.0);
                module.exports.insert("default".into(), "default".into());
            }
            ModuleDeclaration::TSExportAssignment(_)
            | ModuleDeclaration::TSNamespaceExportDeclaration(_) => {}
        }
    }
    Some(module)
}

#[derive(Default)]
struct Analysis {
    modules: HashMap<PathBuf, Option<Module>>,
}

fn resolve_relative(from: &Path, specifier: &str) -> Option<PathBuf> {
    let base = from.parent()?.join(specifier);
    let mut candidates = vec![base.clone()];
    for extension in ["ts", "js"] {
        let mut file = base.clone().into_os_string();
        file.push(format!(".{extension}"));
        candidates.push(PathBuf::from(file));
        candidates.push(base.join(format!("index.{extension}")));
    }
    candidates
        .into_iter()
        .find(|candidate| candidate.is_file())
        .and_then(|file| std::fs::canonicalize(file).ok())
}

impl Analysis {
    fn module(&mut self, path: &Path) -> Option<&Module> {
        if !self.modules.contains_key(path) {
            let module = std::fs::read_to_string(path)
                .ok()
                .and_then(|source| parse(&source));
            self.modules.insert(path.to_path_buf(), module);
        }
        self.modules.get(path).and_then(|module| module.as_ref())
    }

    /// What a name read inside `path` at top level refers to. A name neither
    /// declared nor imported there is a local, a parameter or a global.
    fn binding(&mut self, path: &Path, name: &str) -> Vec<Node> {
        let Some(module) = self.module(path) else {
            return vec![Node::Creates];
        };
        if module.decls.contains_key(name) {
            return vec![Node::Decl(path.to_path_buf(), name.to_string())];
        }
        match module.imports.get(name).cloned() {
            Some((source, what)) => self.import(path, &source, &what),
            None => vec![],
        }
    }

    fn import(&mut self, from: &Path, source: &str, what: &Imported) -> Vec<Node> {
        if source == GRAPH_TS || source.starts_with(&format!("{GRAPH_TS}/")) {
            // `ipfs.map` calls back into a mapping function named by a string,
            // which no reference leads to.
            return match what {
                Imported::Name(name) if name != "DataSourceTemplate" && name != "ipfs" => vec![],
                _ => vec![Node::Creates],
            };
        }
        if !source.starts_with('.') {
            return vec![Node::Creates];
        }
        let Some(target) = resolve_relative(from, source) else {
            return vec![Node::Creates];
        };
        match what {
            Imported::Namespace => vec![Node::Module(target)],
            Imported::Name(name) => self
                .export(&target, name, &mut HashSet::new())
                .unwrap_or_else(|| vec![Node::Creates]),
        }
    }

    /// `None` when the module doesn't export the name at all.
    fn export(
        &mut self,
        path: &Path,
        name: &str,
        visiting: &mut HashSet<PathBuf>,
    ) -> Option<Vec<Node>> {
        if !visiting.insert(path.to_path_buf()) {
            return None;
        }
        let Some(module) = self.module(path) else {
            return Some(vec![Node::Creates]);
        };
        if let Some(local) = module.exports.get(name).cloned() {
            return Some(self.binding(path, &local));
        }
        if let Some((source, what)) = module.reexports.get(name).cloned() {
            return Some(self.import(path, &source, &what));
        }
        for source in module.star_reexports.clone() {
            if !source.starts_with('.') {
                return Some(vec![Node::Creates]);
            }
            let Some(target) = resolve_relative(path, &source) else {
                return Some(vec![Node::Creates]);
            };
            if let Some(found) = self.export(&target, name, visiting) {
                return Some(found);
            }
        }
        None
    }

    fn edges(&mut self, node: &Node) -> Vec<Node> {
        match node {
            Node::Creates => vec![],
            Node::Decl(path, name) => {
                let references: Vec<String> = match self.module(path) {
                    Some(module) => module
                        .decls
                        .get(name)
                        .map(|refs| refs.iter().cloned().collect())
                        .unwrap_or_default(),
                    None => return vec![Node::Creates],
                };
                references
                    .iter()
                    .flat_map(|reference| self.binding(path, reference))
                    .collect()
            }
            Node::Module(path) => {
                let Some(module) = self.module(path) else {
                    return vec![Node::Creates];
                };
                let mut nodes: Vec<Node> = module
                    .decls
                    .keys()
                    .map(|name| Node::Decl(path.clone(), name.clone()))
                    .collect();
                let reexports: Vec<(String, Imported)> = module
                    .reexports
                    .values()
                    .cloned()
                    .chain(
                        module
                            .star_reexports
                            .iter()
                            .map(|source| (source.clone(), Imported::Namespace)),
                    )
                    .collect();
                for (source, what) in reexports {
                    let what = match what {
                        Imported::Name(_) => Imported::Namespace,
                        namespace => namespace,
                    };
                    nodes.extend(self.import(path, &source, &what));
                }
                nodes
            }
        }
    }

    fn creates(&mut self, mapping: &Path, handler: &str) -> bool {
        let Some(start) = self.export(mapping, handler, &mut HashSet::new()) else {
            return true;
        };
        let mut seen: HashSet<Node> = HashSet::new();
        let mut queue: VecDeque<Node> = start.into_iter().collect();
        while let Some(node) = queue.pop_front() {
            if node == Node::Creates {
                return true;
            }
            if !seen.insert(node.clone()) {
                continue;
            }
            queue.extend(self.edges(&node));
        }
        false
    }
}

/// What a top-level declaration's code does with entities: the types it
/// creates (`new E(…)`, `store.set("E", …)`), and the types whose loaded state
/// decides whether, or what, it creates a data source from — a create inside
/// `if (collection)`, after `if (!pool) return`, or handed `entity.address`.
#[derive(Default, Clone)]
struct Facts {
    constructed: HashSet<String>,
    conditioning: HashSet<String>,
}

const LOADS: &[&str] = &["load", "loadInBlock"];

impl Analysis {
    /// The nodes a handler's code reaches, `None` when it can't be followed.
    fn reachable(&mut self, mapping: &Path, handler: &str) -> Option<HashSet<Node>> {
        let start = self.export(mapping, handler, &mut HashSet::new())?;
        let mut seen: HashSet<Node> = HashSet::new();
        let mut queue: VecDeque<Node> = start.into_iter().collect();
        while let Some(node) = queue.pop_front() {
            if seen.insert(node.clone()) {
                queue.extend(self.edges(&node));
            }
        }
        Some(seen)
    }

    fn reaches_creates(&mut self, nodes: Vec<Node>) -> bool {
        let mut seen: HashSet<Node> = HashSet::new();
        let mut queue: VecDeque<Node> = nodes.into_iter().collect();
        while let Some(node) = queue.pop_front() {
            if node == Node::Creates {
                return true;
            }
            if seen.insert(node.clone()) {
                queue.extend(self.edges(&node));
            }
        }
        false
    }

    /// The entity a name in `path` refers to: a class of graph codegen's
    /// `schema` module.
    fn entity(&mut self, path: &Path, name: &str) -> Option<String> {
        self.binding(path, name)
            .into_iter()
            .find_map(|node| match node {
                Node::Decl(file, class)
                    if file.file_stem().is_some_and(|stem| stem == "schema") =>
                {
                    Some(class)
                }
                _ => None,
            })
    }

    /// The facts of every top-level declaration in `path`, by name. graph
    /// codegen's own entity classes construct nothing a mapping didn't ask for.
    fn facts(&mut self, path: &Path) -> HashMap<String, Facts> {
        if path.file_stem().is_some_and(|stem| stem == "schema") {
            return HashMap::new();
        }
        let Ok(source) = std::fs::read_to_string(path) else {
            return HashMap::new();
        };
        let allocator = Allocator::default();
        let parsed = Parser::new(&allocator, &source, SourceType::ts()).parse();
        if parsed.panicked || parsed.diagnostics.has_errors() {
            return HashMap::new();
        }
        let mut facts = HashMap::new();
        for statement in &parsed.program.body {
            let declaration = match statement {
                Statement::ExportNamedDeclaration(_) => None,
                Statement::ExportDeclaration(export) => Some(&export.declaration),
                other => other.as_declaration(),
            };
            let Some(declaration) = declaration else {
                continue;
            };
            let mut bindings = Bindings::default();
            bindings.visit_declaration(declaration);
            let mut scan = EntityScan {
                analysis: self,
                path,
                loads: HashMap::new(),
                conditions: vec![],
                guards: HashSet::new(),
                facts: Facts::default(),
            };
            scan.visit_declaration(declaration);
            let found = scan.facts;
            for name in bindings.0 {
                facts.insert(name, found.clone());
            }
        }
        facts
    }
}

struct EntityScan<'x> {
    analysis: &'x mut Analysis,
    path: &'x Path,
    /// Locals holding a loaded entity, by the entity's type.
    loads: HashMap<String, String>,
    /// The entity types each enclosing branch's condition reads.
    conditions: Vec<HashSet<String>>,
    /// The entity types of an earlier `if (…) return` the code passed.
    guards: HashSet<String>,
    facts: Facts,
}

/// `E.load(…)` or `store.get("E", …)`, through `!`, `as` and `changetype`.
fn loaded_entity(scan: &mut EntityScan<'_>, expr: &Expression<'_>) -> Option<String> {
    match expr.without_parentheses() {
        Expression::TSNonNullExpression(inner) => loaded_entity(scan, &inner.expression),
        Expression::TSAsExpression(cast) => loaded_entity(scan, &cast.expression),
        Expression::CallExpression(call) => loaded_by_call(scan, call),
        _ => None,
    }
}

fn loaded_by_call(scan: &mut EntityScan<'_>, call: &CallExpression<'_>) -> Option<String> {
    match &call.callee {
        Expression::Identifier(callee) if callee.name == "changetype" => {
            loaded_entity(scan, call.arguments.first()?.as_expression()?)
        }
        Expression::StaticMemberExpression(member) => {
            let Expression::Identifier(object) = &member.object else {
                return None;
            };
            let method = member.property.name.as_str();
            if object.name == "store" && (method == "get" || method == "get_in_block") {
                return match call.arguments.first()?.as_expression()? {
                    Expression::StringLiteral(name) => Some(name.value.to_string()),
                    _ => None,
                };
            }
            if !LOADS.contains(&method) {
                return None;
            }
            scan.analysis.entity(scan.path, object.name.as_str())
        }
        _ => None,
    }
}

impl EntityScan<'_> {
    /// The entity types an expression reads: loaded locals it names, and loads
    /// it makes.
    fn entities_in(&mut self, expr: &Expression<'_>) -> HashSet<String> {
        let mut names = References::default();
        names.visit_expression(expr);
        let mut found: HashSet<String> = names
            .0
            .iter()
            .filter_map(|name| self.loads.get(name).cloned())
            .collect();
        let mut direct = DirectLoads(vec![]);
        direct.visit_expression(expr);
        for load in direct.0 {
            found.extend(self.load_name(&load));
        }
        found
    }

    fn load_name(&mut self, load: &(String, Option<String>)) -> Option<String> {
        match load {
            (_, Some(literal)) => Some(literal.clone()),
            (object, None) => self.analysis.entity(self.path, object),
        }
    }

    fn create_reaching(&mut self, call: &CallExpression<'_>) -> bool {
        let name = match &call.callee {
            Expression::Identifier(callee) => callee.name.as_str(),
            Expression::StaticMemberExpression(member) => match &member.object {
                Expression::Identifier(object) => object.name.as_str(),
                _ => return false,
            },
            _ => return false,
        };
        let nodes = self.analysis.binding(self.path, name);
        !nodes.is_empty() && self.analysis.reaches_creates(nodes)
    }

    fn within<F: FnOnce(&mut Self)>(&mut self, condition: HashSet<String>, visit: F) {
        self.conditions.push(condition);
        visit(self);
        self.conditions.pop();
    }
}

/// The `E.load(…)` / `store.get("E", …)` calls in an expression: the object's
/// name, or the literal type name.
struct DirectLoads(Vec<(String, Option<String>)>);

impl<'a> Visit<'a> for DirectLoads {
    fn visit_call_expression(&mut self, call: &CallExpression<'a>) {
        if let Expression::StaticMemberExpression(member) = &call.callee {
            if let Expression::Identifier(object) = &member.object {
                let method = member.property.name.as_str();
                if object.name == "store" && (method == "get" || method == "get_in_block") {
                    if let Some(Expression::StringLiteral(name)) = call
                        .arguments
                        .first()
                        .and_then(|argument| argument.as_expression())
                    {
                        self.0.push((String::new(), Some(name.value.to_string())));
                    }
                } else if LOADS.contains(&method) {
                    self.0.push((object.name.to_string(), None));
                }
            }
        }
        oxc::ast_visit::walk::walk_call_expression(self, call);
    }
}

/// Whether a branch always leaves the function — `if (…) return`, a block
/// ending in a return — so its condition guards what follows. A return nested
/// under a further condition doesn't count: Uniswap's factory returns only
/// when a new token's decimals can't be read.
fn exits(statement: &Statement<'_>) -> bool {
    match statement {
        Statement::ReturnStatement(_) | Statement::ThrowStatement(_) => true,
        Statement::BlockStatement(block) => block.body.iter().any(|statement| {
            matches!(
                statement,
                Statement::ReturnStatement(_) | Statement::ThrowStatement(_)
            )
        }),
        _ => false,
    }
}

impl<'a> Visit<'a> for EntityScan<'_> {
    fn visit_variable_declarator(&mut self, declarator: &VariableDeclarator<'a>) {
        oxc::ast_visit::walk::walk_variable_declarator(self, declarator);
        if let (BindingPattern::BindingIdentifier(id), Some(init)) =
            (&declarator.id, &declarator.init)
        {
            if let Some(entity) = loaded_entity(self, init) {
                self.loads.insert(id.name.to_string(), entity);
            }
        }
    }

    fn visit_assignment_expression(&mut self, assign: &AssignmentExpression<'a>) {
        oxc::ast_visit::walk::walk_assignment_expression(self, assign);
        if let AssignmentTarget::AssignmentTargetIdentifier(id) = &assign.left {
            if let Some(entity) = loaded_entity(self, &assign.right) {
                self.loads.insert(id.name.to_string(), entity);
            }
        }
    }

    fn visit_new_expression(&mut self, new: &NewExpression<'a>) {
        if let Expression::Identifier(class) = &new.callee {
            if let Some(entity) = self.analysis.entity(self.path, class.name.as_str()) {
                self.facts.constructed.insert(entity);
            }
        }
        oxc::ast_visit::walk::walk_new_expression(self, new);
    }

    fn visit_if_statement(&mut self, statement: &IfStatement<'a>) {
        self.visit_expression(&statement.test);
        let condition = self.entities_in(&statement.test);
        self.within(condition.clone(), |scan| {
            scan.visit_statement(&statement.consequent);
            if let Some(alternate) = &statement.alternate {
                scan.visit_statement(alternate);
            }
        });
        if exits(&statement.consequent) {
            self.guards.extend(condition);
        }
    }

    fn visit_conditional_expression(&mut self, expr: &ConditionalExpression<'a>) {
        self.visit_expression(&expr.test);
        let condition = self.entities_in(&expr.test);
        self.within(condition, |scan| {
            scan.visit_expression(&expr.consequent);
            scan.visit_expression(&expr.alternate);
        });
    }

    fn visit_logical_expression(&mut self, expr: &LogicalExpression<'a>) {
        self.visit_expression(&expr.left);
        let condition = self.entities_in(&expr.left);
        self.within(condition, |scan| scan.visit_expression(&expr.right));
    }

    fn visit_while_statement(&mut self, statement: &WhileStatement<'a>) {
        self.visit_expression(&statement.test);
        let condition = self.entities_in(&statement.test);
        self.within(condition, |scan| scan.visit_statement(&statement.body));
    }

    fn visit_for_statement(&mut self, statement: &ForStatement<'a>) {
        if let Some(init) = &statement.init {
            self.visit_for_statement_init(init);
        }
        let condition = match &statement.test {
            Some(test) => {
                self.visit_expression(test);
                self.entities_in(test)
            }
            None => HashSet::new(),
        };
        self.within(condition, |scan| {
            if let Some(update) = &statement.update {
                scan.visit_expression(update);
            }
            scan.visit_statement(&statement.body);
        });
    }

    fn visit_call_expression(&mut self, call: &CallExpression<'a>) {
        oxc::ast_visit::walk::walk_call_expression(self, call);
        if let Expression::StaticMemberExpression(member) = &call.callee {
            if matches!(&member.object, Expression::Identifier(object) if object.name == "store")
                && member.property.name == "set"
            {
                if let Some(Expression::StringLiteral(name)) = call
                    .arguments
                    .first()
                    .and_then(|argument| argument.as_expression())
                {
                    self.facts.constructed.insert(name.value.to_string());
                }
            }
        }
        if self.create_reaching(call) {
            let mut conditioning: HashSet<String> =
                self.conditions.iter().flatten().cloned().collect();
            conditioning.extend(self.guards.iter().cloned());
            for argument in &call.arguments {
                if let Some(argument) = argument.as_expression() {
                    conditioning.extend(self.entities_in(argument));
                }
            }
            self.facts.conditioning.extend(conditioning);
        }
    }
}

/// For every data source, the handlers that need a register pass: those whose
/// code can reach a create, and those that create an entity whose loaded state
/// decides a create — Heavy Helms' `handleSkinRegistered` saves the new
/// `SkinCollection` that `handleSkinVerificationUpdated` loads before it
/// creates a template, and a register store without it skips the create.
/// Uniswap's pool factory creates whatever it loaded, so its pool's handlers
/// stay without one; so does a handler that only updates an entity a create
/// checks for (crvUSD's Llamma handlers and its Market): the handler that
/// created the entity had its pass.
pub fn register_handlers(sources: &[(PathBuf, Vec<String>)]) -> Vec<Vec<String>> {
    let mut analysis = Analysis::default();
    let mut file_facts: HashMap<PathBuf, HashMap<String, Facts>> = HashMap::new();
    let mut handler_facts = |analysis: &mut Analysis, mapping: &Path, handler: &str| {
        let reached = analysis.reachable(mapping, handler)?;
        let mut facts = Facts::default();
        for node in reached {
            let Node::Decl(path, name) = node else {
                continue;
            };
            if !file_facts.contains_key(&path) {
                let found = analysis.facts(&path);
                file_facts.insert(path.clone(), found);
            }
            if let Some(found) = file_facts[&path].get(&name) {
                facts.constructed.extend(found.constructed.iter().cloned());
                facts
                    .conditioning
                    .extend(found.conditioning.iter().cloned());
            }
        }
        Some(facts)
    };

    let mut plans: Vec<Vec<(String, bool, Option<Facts>)>> = vec![];
    let mut conditioning: HashSet<String> = HashSet::new();
    for (mapping, handlers) in sources {
        let Ok(mapping) = std::fs::canonicalize(mapping) else {
            plans.push(handlers.iter().map(|h| (h.clone(), true, None)).collect());
            continue;
        };
        let mut plan = vec![];
        for handler in handlers {
            let creates = analysis.creates(&mapping, handler);
            let facts = handler_facts(&mut analysis, &mapping, handler);
            if creates {
                if let Some(facts) = &facts {
                    conditioning.extend(facts.conditioning.iter().cloned());
                }
            }
            plan.push((handler.clone(), creates, facts));
        }
        plans.push(plan);
    }
    plans
        .into_iter()
        .map(|plan| {
            plan.into_iter()
                .filter(|(_, creates, facts)| {
                    *creates
                        || facts
                            .as_ref()
                            .is_none_or(|facts| !facts.constructed.is_disjoint(&conditioning))
                })
                .map(|(handler, _, _)| handler)
                .collect()
        })
        .collect()
}

/// The subset of `handlers`, exported by the mapping at `mapping`, whose code
/// can reach a `DataSourceTemplate.create`.
pub fn creating_handlers(mapping: &Path, handlers: &[String]) -> Vec<String> {
    let mut analysis = Analysis::default();
    let Ok(mapping) = std::fs::canonicalize(mapping) else {
        return handlers.to_vec();
    };
    handlers
        .iter()
        .filter(|handler| analysis.creates(&mapping, handler))
        .cloned()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempdir::TempDir;

    fn project(files: &[(&str, &str)]) -> TempDir {
        let dir = TempDir::new("envio_subgraph_creates").unwrap();
        for (path, source) in files {
            let file = dir.path().join(path);
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(file, source).unwrap();
        }
        dir
    }

    fn creating(dir: &TempDir, mapping: &str, handlers: &[&str]) -> Vec<String> {
        let handlers: Vec<String> = handlers.iter().map(|h| h.to_string()).collect();
        creating_handlers(&dir.path().join(mapping), &handlers)
    }

    const TEMPLATES: &str = r#"
import { Address, DataSourceTemplate } from "@graphprotocol/graph-ts";
export class Pool extends DataSourceTemplate {
  static create(address: Address): void {
    DataSourceTemplate.create("Pool", [address.toHex()]);
  }
}
"#;

    #[test]
    fn follows_helpers_across_files_into_generated_templates() {
        let dir = project(&[
            ("generated/templates.ts", TEMPLATES),
            (
                "src/helpers.ts",
                r#"
import { Pool as PoolTemplate } from "../generated/templates";
import { BigInt } from "@graphprotocol/graph-ts";
export function getOrCreatePool(address: string): void {
  PoolTemplate.create(address);
}
export function bump(value: BigInt): BigInt { return value.plus(BigInt.fromI32(1)); }
"#,
            ),
            (
                "src/factory.ts",
                r#"
import { getOrCreatePool, bump } from "./helpers";
import { Swap } from "../generated/Pool/Pool";
function indirect(e: Swap): void { getOrCreatePool(e.address.toHex()); }
export function handleCreated(event: Swap): void { indirect(event); }
export function handleSwap(event: Swap): void { bump(event.params.amount); }
"#,
            ),
            (
                "generated/Pool/Pool.ts",
                r#"
import { ethereum, BigInt } from "@graphprotocol/graph-ts";
export class Swap extends ethereum.Event {
  get params(): Swap__Params { return new Swap__Params(this); }
}
export class Swap__Params { constructor(public event: Swap) {} get amount(): BigInt { return this.event.parameters[0].value.toBigInt(); } }
"#,
            ),
        ]);
        assert_eq!(
            creating(&dir, "src/factory.ts", &["handleCreated", "handleSwap"]),
            vec!["handleCreated".to_string()]
        );
    }

    // Dolomite: codegen into `src/types`, where `templates.ts` sits beside a
    // `templates/` directory, and the template imported under an alias because
    // the schema entity has its name.
    #[test]
    fn follows_an_aliased_template_import_beside_a_templates_directory() {
        let dir = project(&[
            ("src/types/templates.ts", TEMPLATES),
            ("src/types/templates/Pool/Pool.ts", "export class Sync {}\n"),
            (
                "src/types/schema.ts",
                r#"
import { Entity, store } from "@graphprotocol/graph-ts";
export class Pool extends Entity {
  save(): void { store.set("Pool", "id", this); }
}
"#,
            ),
            (
                "src/mappings/factory.ts",
                r#"
import { Pool } from "../types/schema";
import { Pool as PoolTemplate } from "../types/templates";
export function handleNewPair(event: any): void {
  new Pool().save();
  PoolTemplate.create(event.params.pair);
}
export function handleSync(event: any): void { new Pool().save(); }
"#,
            ),
        ]);
        assert_eq!(
            creating(
                &dir,
                "src/mappings/factory.ts",
                &["handleNewPair", "handleSync"]
            ),
            vec!["handleNewPair".to_string()]
        );
    }

    #[test]
    fn assumes_a_create_behind_whatever_it_cannot_see() {
        let dir = project(&[
            (
                "src/mapping.ts",
                r#"
import { helper } from "some-package";
import { missing } from "./not-there";
import * as graph from "@graphprotocol/graph-ts";
export function viaPackage(): void { helper(); }
export function viaMissingFile(): void { missing(); }
export function viaNamespace(): void { graph.log.info("x", []); }
export function plain(): void {}
"#,
            ),
            (
                "src/files.ts",
                r#"
import { ipfs, Bytes } from "@graphprotocol/graph-ts";
export function processItem(value: Bytes): void {}
export function viaIpfsMap(): void { ipfs.map("Qm", "processItem", null, []); }
"#,
            ),
        ]);
        assert_eq!(
            creating(&dir, "src/files.ts", &["viaIpfsMap"]),
            vec!["viaIpfsMap".to_string()]
        );
        assert_eq!(
            creating(
                &dir,
                "src/mapping.ts",
                &[
                    "viaPackage",
                    "viaMissingFile",
                    "viaNamespace",
                    "plain",
                    "notExported"
                ]
            ),
            vec![
                "viaPackage".to_string(),
                "viaMissingFile".to_string(),
                "viaNamespace".to_string(),
                "notExported".to_string(),
            ]
        );
    }

    #[test]
    fn follows_reexports_and_unparseable_files() {
        let dir = project(&[
            ("generated/templates.ts", TEMPLATES),
            ("src/index.ts", "export * from \"./factory\";\nexport { handleSync } from \"./pair\";\n"),
            (
                "src/factory.ts",
                "import { Pool } from \"../generated/templates\";\nexport function handleCreated(): void { Pool.create(\"0x\"); }\n",
            ),
            ("src/pair.ts", "export function handleSync(): void {}\n"),
            ("src/broken.ts", "export function handleBroken(: void {\n"),
        ]);
        assert_eq!(
            creating(&dir, "src/index.ts", &["handleCreated", "handleSync"]),
            vec!["handleCreated".to_string()]
        );
        assert_eq!(
            creating(&dir, "src/broken.ts", &["handleBroken"]),
            vec!["handleBroken".to_string()]
        );
    }

    const SCHEMA: &str = r#"
import { Entity, store } from "@graphprotocol/graph-ts";
export class SkinCollection extends Entity {
  static load(id: string): SkinCollection | null { return null; }
  save(): void { store.set("SkinCollection", "id", this); }
}
export class Factory extends Entity {
  static load(id: string): Factory | null { return null; }
  save(): void { store.set("Factory", "id", this); }
}
"#;

    fn registered(dir: &TempDir, sources: &[(&str, &[&str])]) -> Vec<Vec<String>> {
        let sources: Vec<(PathBuf, Vec<String>)> = sources
            .iter()
            .map(|(mapping, handlers)| {
                (
                    dir.path().join(mapping),
                    handlers.iter().map(|h| h.to_string()).collect(),
                )
            })
            .collect();
        register_handlers(&sources)
    }

    // Heavy Helms: the create hangs on a SkinCollection another handler saves,
    // so that handler needs a register pass too; one that touches neither
    // doesn't.
    #[test]
    fn registers_the_writers_of_an_entity_a_create_depends_on() {
        let dir = project(&[
            ("generated/templates.ts", TEMPLATES),
            ("generated/schema.ts", SCHEMA),
            (
                "src/registry.ts",
                r#"
import { log } from "@graphprotocol/graph-ts";
import { SkinCollection } from "../generated/schema";
import { Pool as PoolTemplate } from "../generated/templates";
export function handleRegistered(event: any): void {
  let collection = new SkinCollection(event.params.id);
  collection.save();
}
export function handleVerified(event: any): void {
  let collection = SkinCollection.load(event.params.id);
  if (collection) {
    PoolTemplate.create(collection.address);
  }
}
export function handlePing(event: any): void { log.info("ping", []); }
"#,
            ),
        ]);
        assert_eq!(
            registered(
                &dir,
                &[(
                    "src/registry.ts",
                    &["handleRegistered", "handleVerified", "handlePing"]
                )]
            ),
            vec![vec![
                "handleRegistered".to_string(),
                "handleVerified".to_string()
            ]]
        );
    }

    // Uniswap's factory creates the pool whatever its Factory load found, so
    // the pool's handlers that save the Factory stay without a register pass;
    // an early return on a load, or a raw store read, conditions the create.
    #[test]
    fn leaves_out_writers_when_the_create_does_not_depend_on_them() {
        let dir = project(&[
            ("generated/templates.ts", TEMPLATES),
            ("generated/schema.ts", SCHEMA),
            (
                "src/factory.ts",
                r#"
import { DataSourceTemplate, store } from "@graphprotocol/graph-ts";
import { Factory, SkinCollection } from "../generated/schema";
import { Pool as PoolTemplate } from "../generated/templates";
export function handlePoolCreated(event: any): void {
  let factory = Factory.load("1");
  if (factory === null) {
    factory = new Factory("1");
  }
  PoolTemplate.create(event.params.pool);
  factory.save();
}
export function handleGuarded(event: any): void {
  let collection = SkinCollection.load(event.params.id);
  if (collection == null) return;
  PoolTemplate.create(event.params.pool);
}
export function handleRaw(event: any): void {
  if (store.get("Config", "1") != null) DataSourceTemplate.create("Pool", [event.params.pool]);
}
"#,
            ),
            (
                "src/pool.ts",
                r#"
import { store } from "@graphprotocol/graph-ts";
import { Factory, SkinCollection } from "../generated/schema";
export function handleSwap(event: any): void {
  let factory = Factory.load("1")!;
  factory.save();
}
export function handleSkin(event: any): void { new SkinCollection("1").save(); }
export function handleConfigured(event: any): void { store.set("Config", "1", event); }
"#,
            ),
        ]);
        assert_eq!(
            registered(
                &dir,
                &[
                    (
                        "src/factory.ts",
                        &["handlePoolCreated", "handleGuarded", "handleRaw"]
                    ),
                    (
                        "src/pool.ts",
                        &["handleSwap", "handleSkin", "handleConfigured"]
                    ),
                ]
            ),
            vec![
                vec![
                    "handlePoolCreated".to_string(),
                    "handleGuarded".to_string(),
                    "handleRaw".to_string()
                ],
                vec!["handleSkin".to_string(), "handleConfigured".to_string()],
            ]
        );
    }
}
