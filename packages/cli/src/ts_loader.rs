use base64::Engine;
use oxc_resolver::{CompilerOptions, ResolveOptions, Resolver, TsConfig};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock};
use url::Url;

// Resolution follows tsx's ESM resolver so handlers that ran under tsx resolve
// the same files. Node still resolves every candidate; this module only decides
// which candidates to offer and in what order.
const PROJECT_EXTENSIONS: &[&str] = &[".ts", ".tsx", ".js", ".json"];
const DEPENDENCY_EXTENSIONS: &[&str] = &[".js", ".json", ".ts", ".tsx"];
// A specifier ending in one of these names its file; nothing gets appended.
const MODULE_EXTENSIONS: &[&str] = &[
    ".js", ".mjs", ".cjs", ".jsx", ".ts", ".mts", ".cts", ".tsx", ".json", ".node",
];

struct Project {
    tsconfig: Option<Arc<TsConfig>>,
}

impl Project {
    fn option(&self, get: impl Fn(&CompilerOptions) -> Option<bool>) -> bool {
        self.tsconfig
            .as_ref()
            .is_some_and(|tsconfig| get(&tsconfig.compiler_options) == Some(true))
    }

    fn allow_js(&self) -> bool {
        self.option(|options| options.allow_js)
    }

    fn path_candidates(&self, specifier: &str) -> Vec<PathBuf> {
        self.tsconfig.as_ref().map_or_else(Vec::new, |tsconfig| {
            tsconfig.resolve_path_alias_or_base_url(specifier)
        })
    }
}

/// The tsconfig.json found from the working directory upwards, as tsx loads
/// it: one config, with `extends` followed, for every handler module.
fn project() -> &'static Project {
    static PROJECT: LazyLock<Project> = LazyLock::new(|| {
        let tsconfig = std::env::current_dir().ok().and_then(|cwd| {
            let path = cwd
                .ancestors()
                .map(|directory| directory.join("tsconfig.json"))
                .find(|path| path.is_file())?;
            Resolver::new(ResolveOptions::default())
                .resolve_tsconfig(path)
                .ok()
        });
        Project { tsconfig }
    });
    &PROJECT
}

fn is_relative(specifier: &str) -> bool {
    matches!(specifier, "." | "..") || specifier.starts_with("./") || specifier.starts_with("../")
}

fn is_file_path(specifier: &str) -> bool {
    is_relative(specifier) || Path::new(specifier).is_absolute()
}

/// Relative, absolute and URL specifiers, which `paths` never applies to.
fn is_path_like(specifier: &str) -> bool {
    is_file_path(specifier)
        || specifier
            .find(':')
            .is_some_and(|colon| colon > 0 && &specifier[..colon] != "node")
}

fn is_directory(specifier: &str) -> bool {
    specifier.ends_with('/') || specifier.contains("/?")
}

fn is_typescript(url: &str) -> bool {
    let path = url.split('?').next().unwrap_or(url);
    [".ts", ".mts", ".tsx"]
        .iter()
        .any(|extension| path.ends_with(extension))
}

fn extension(path: &str) -> &str {
    let file = path.rsplit('/').next().unwrap_or(path);
    match file.rfind('.') {
        Some(dot) if dot > 0 => &file[dot..],
        _ => "",
    }
}

fn extension_candidates(url: &str) -> Vec<String> {
    let (path, suffix) = match url.split_once('?') {
        Some((path, query)) => (path, format!("?{query}")),
        None => (url, String::new()),
    };
    let mut candidates = Vec::new();
    let implicit: &[&str] = match extension(path) {
        ".js" => &[".ts", ".tsx", ".js"],
        ".mjs" => &[".mts"],
        _ => &[],
    };
    let base = &path[..path.len() - extension(path).len()];
    candidates.extend(
        implicit
            .iter()
            .map(|replacement| format!("{base}{replacement}{suffix}")),
    );
    if MODULE_EXTENSIONS.contains(&extension(path)) {
        return candidates;
    }
    let from_dependency =
        !(url.starts_with("file://") || is_file_path(path)) || path.contains("/node_modules/");
    let appended = if from_dependency {
        DEPENDENCY_EXTENSIONS
    } else {
        PROJECT_EXTENSIONS
    };
    candidates.extend(
        appended
            .iter()
            .map(|added| format!("{path}{added}{suffix}")),
    );
    candidates
}

fn index_candidates(url: &str) -> Vec<String> {
    extension_candidates(&format!("{}/index", url.trim_end_matches('/')))
}

/// Specifiers to hand Node's resolver, in order, before the specifier itself.
pub fn resolve_candidates(specifier: &str, parent_url: Option<&str>) -> Vec<String> {
    let project = project();
    // A dependency resolves as Node resolves it, apart from the retry after a
    // miss. Probing TypeScript siblings first, as tsx does under `allowJs`,
    // can't find anything there (Node won't load TypeScript from
    // `node_modules`) and doubled the time to import a package like viem.
    let from_dependency = parent_url.is_some_and(|url| url.contains("/node_modules/"));
    let typescript_mode =
        !from_dependency && (parent_url.is_some_and(is_typescript) || project.allow_js());
    let mut candidates = Vec::new();

    if !is_path_like(specifier) && !from_dependency {
        for path in project.path_candidates(specifier) {
            let Ok(url) = Url::from_file_path(&path) else {
                continue;
            };
            let url = url.to_string();
            if is_directory(&url) {
                candidates.extend(index_candidates(&url));
                continue;
            }
            if typescript_mode {
                candidates.extend(extension_candidates(&url));
                candidates.push(url.clone());
            } else {
                candidates.push(url.clone());
                candidates.extend(extension_candidates(&url));
            }
            candidates.extend(index_candidates(&url));
        }
    }

    let specifier = match specifier {
        "." | ".." => format!("{specifier}/"),
        _ if specifier.ends_with("/..") => format!("{specifier}/"),
        _ => specifier.to_string(),
    };
    if is_directory(&specifier) {
        let parent = parent_url.and_then(|url| Url::parse(url).ok());
        if let Some(url) = parent.and_then(|parent| parent.join(&specifier).ok()) {
            candidates.extend(index_candidates(url.as_str()));
        }
    } else if (specifier.starts_with("file://") || is_relative(&specifier)) && typescript_mode {
        candidates.extend(extension_candidates(&specifier));
    }
    let parent = parent_url.and_then(|url| Url::parse(url).ok());
    existing(candidates, parent.as_ref())
}

// Each candidate Node can't find costs it a thrown error, so only files that
// exist are offered. A candidate whose file can't be told stays for Node.
fn existing(candidates: Vec<String>, parent: Option<&Url>) -> Vec<String> {
    candidates
        .into_iter()
        .filter(|candidate| {
            let target = candidate.split('?').next().unwrap_or(candidate);
            let path = if Path::new(target).is_absolute() {
                Some(PathBuf::from(target))
            } else {
                let url = match parent {
                    Some(parent) => parent.join(target),
                    None => Url::parse(target),
                };
                url.ok().and_then(|url| url.to_file_path().ok())
            };
            path.is_none_or(|path| path.is_file())
        })
        .collect()
}

/// Specifiers to retry after Node rejected one, built from the path its error
/// names.
pub fn not_found_candidates(code: &str, url: Option<&str>, message: &str) -> Vec<String> {
    let Some(missing) = url
        .map(str::to_string)
        .or_else(|| missing_from_message(message))
    else {
        return Vec::new();
    };
    let candidates = match code {
        "ERR_MODULE_NOT_FOUND" => extension_candidates(&missing),
        "ERR_UNSUPPORTED_DIR_IMPORT" => index_candidates(&missing),
        _ => Vec::new(),
    };
    existing(candidates, None)
}

fn quoted_after<'a>(message: &'a str, prefix: &str) -> Option<&'a str> {
    let rest = message.strip_prefix(prefix)?;
    rest.split('\'').next()
}

fn missing_from_message(message: &str) -> Option<String> {
    if let Some(module) = quoted_after(message, "Cannot find module '") {
        return Some(module.to_string());
    }
    let package = Path::new(quoted_after(message, "Cannot find package '")?);
    if !package.is_absolute() {
        return None;
    }
    let mut url = Url::from_file_path(package).ok()?;
    if url.path().ends_with('/') {
        url = url.join("package.json").ok()?;
    }
    if !url.path().ends_with("/package.json") {
        return Some(url.to_string());
    }
    let manifest = std::fs::read_to_string(url.to_file_path().ok()?).ok()?;
    let main = serde_json::from_str::<serde_json::Value>(&manifest)
        .ok()?
        .get("main")?
        .as_str()?
        .to_string();
    Some(url.join(&main).ok()?.to_string())
}

pub fn load(path: &Path) -> Result<String, String> {
    let file = path.display();
    if path.extension().is_some_and(|extension| extension == "cts") {
        return Err(format!(
            "{file} can't load: .cts files are CommonJS, and envio loads TypeScript as ES modules. Rename it to .ts or .mts."
        ));
    }
    let source =
        std::fs::read_to_string(path).map_err(|error| format!("Failed reading {file}: {error}"))?;
    // A panic would otherwise abort the whole process, since it can't unwind
    // into Node.
    let (code, map) =
        std::panic::catch_unwind(|| transform(path, &source)).unwrap_or_else(|panic| {
            let reason = panic
                .downcast_ref::<String>()
                .map(String::as_str)
                .or_else(|| panic.downcast_ref::<&str>().copied())
                .unwrap_or("unknown panic");
            Err(format!("Failed transforming {file}: {reason}"))
        })?;
    Ok(match map {
        Some(map) => format!(
            "{code}\n//# sourceMappingURL=data:application/json;base64,{}",
            base64::engine::general_purpose::STANDARD.encode(map)
        ),
        None => code,
    })
}

/// Handlers have to be ES modules. A module they import doesn't: it loads as
/// one whatever its package.json says, as a workspace package often says
/// nothing.
pub fn check_handler_format(path: &Path) -> Result<(), String> {
    if path.extension().is_some_and(|extension| extension == "mts") {
        return Ok(());
    }
    let file = path.display();
    let Some(manifest) = path
        .ancestors()
        .skip(1)
        .map(|directory| directory.join("package.json"))
        .find(|manifest| manifest.is_file())
    else {
        return Err(format!(
            "{file} can't load: envio handlers are ES modules, and no package.json above it declares them. Add one with \"type\": \"module\"."
        ));
    };
    let is_module = std::fs::read_to_string(&manifest)
        .ok()
        .and_then(|contents| serde_json::from_str::<serde_json::Value>(&contents).ok())
        .is_some_and(|json| json.get("type").and_then(|kind| kind.as_str()) == Some("module"));
    if is_module {
        Ok(())
    } else {
        Err(format!(
            "{file} can't load: envio handlers are ES modules, and {} doesn't declare them. Add \"type\": \"module\" to it.",
            manifest.display()
        ))
    }
}

#[derive(Default)]
struct FirstDecorator(Option<oxc::span::Span>);

impl<'a> oxc::ast_visit::Visit<'a> for FirstDecorator {
    fn visit_decorator(&mut self, decorator: &oxc::ast::ast::Decorator<'a>) {
        self.0.get_or_insert(decorator.span);
    }
}

/// Strips types and lowers the syntax Node can't run (enums, namespaces,
/// legacy decorators), following the tsconfig's `verbatimModuleSyntax` and
/// `experimentalDecorators`. The source map is always emitted so stack traces
/// name the user's TypeScript lines.
fn transform(path: &Path, source: &str) -> Result<(String, Option<String>), String> {
    use oxc::allocator::Allocator;
    use oxc::ast_visit::Visit;
    use oxc::codegen::{Codegen, CodegenOptions};
    use oxc::diagnostics::{
        Diagnostics, GraphicalReportHandler, GraphicalTheme, NamedSource, OxcDiagnostic,
    };
    use oxc::parser::Parser;
    use oxc::semantic::SemanticBuilder;
    use oxc::span::SourceType;
    use oxc::transformer::{
        DecoratorOptions, HelperLoaderMode, HelperLoaderOptions, TransformOptions, Transformer,
        TypeScriptOptions,
    };

    let project = project();
    let options = TransformOptions {
        typescript: TypeScriptOptions {
            // Without it an import whose bindings go unused is dropped, as tsc
            // drops it, and the module's side effects with it.
            only_remove_type_imports: project.option(|options| options.verbatim_module_syntax),
            ..TypeScriptOptions::default()
        },
        decorator: DecoratorOptions {
            legacy: project.option(|options| options.experimental_decorators),
            emit_decorator_metadata: project.option(|options| options.emit_decorator_metadata),
            ..DecoratorOptions::default()
        },
        // The default imports helpers from `@oxc-project/runtime`, which the
        // user's project doesn't have, and inlining isn't implemented. These
        // call the global `babelHelpers` that TsModuleHooks.mjs defines.
        helper_loader: HelperLoaderOptions {
            mode: HelperLoaderMode::External,
            ..HelperLoaderOptions::default()
        },
        ..TransformOptions::default()
    };

    let file = path.display();
    let source_type = SourceType::from_path(path)
        .map_err(|_| format!("Unsupported handler file extension: {file}"))?;
    let report = |stage: &str, diagnostics: Diagnostics| {
        // No colors: the message goes through the logger and into error
        // strings, where escape codes would show up raw.
        let handler = GraphicalReportHandler::new_themed(GraphicalTheme::unicode_nocolor());
        let mut rendered = String::new();
        for diagnostic in diagnostics {
            let diagnostic =
                diagnostic.with_source_code(NamedSource::new(file.to_string(), source.to_string()));
            if handler
                .render_report(&mut rendered, diagnostic.as_ref())
                .is_err()
            {
                rendered.push_str(&format!("{diagnostic}\n"));
            }
        }
        format!(
            "Failed {stage} {file}:\n{}",
            rendered.trim_start_matches('\n')
        )
    };

    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, source, source_type).parse();
    if !parsed.diagnostics.is_empty() {
        return Err(report("parsing", parsed.diagnostics));
    }

    let mut program = parsed.program;
    // Only legacy decorators get lowered, and Node can't run standard ones yet.
    if !options.decorator.legacy {
        let mut first = FirstDecorator::default();
        first.visit_program(&program);
        if let Some(span) = first.0 {
            let diagnostic = OxcDiagnostic::error(
                "Decorators need \"experimentalDecorators\": true in tsconfig.json.",
            )
            .with_label(span);
            return Err(report("transforming", vec![diagnostic].into()));
        }
    }

    // `with_enum_eval` is what lets the transformer resolve enum member values;
    // without it, lowering an `enum` panics.
    let scoping = SemanticBuilder::new()
        .with_enum_eval(true)
        .build(&program)
        .semantic
        .into_scoping();
    let transformed =
        Transformer::new(&allocator, path, &options).build_with_scoping(scoping, &mut program);
    if !transformed.diagnostics.is_empty() {
        return Err(report("transforming", transformed.diagnostics));
    }

    let generated = Codegen::new()
        .with_options(CodegenOptions {
            source_map_path: Some(path.to_path_buf()),
            ..CodegenOptions::default()
        })
        .build(&program);
    Ok((
        generated.code,
        generated.map.map(|map| map.to_json_string()),
    ))
}
