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
}
