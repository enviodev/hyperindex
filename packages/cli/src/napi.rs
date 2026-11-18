use crate::{
    clap_definitions::CommandLineArgs, config_parsing::system_config::SystemConfig,
    hbs_templating::codegen_templates::ProjectTemplate, project_paths::ParsedProjectPaths,
};
use anyhow::Context;
use clap::{CommandFactory, FromArgMatches};
use std::collections::HashMap;

#[derive(Default)]
#[napi_derive::napi(object)]
pub struct FromUserApiOptions {
    pub schema: Option<String>,
    pub env: Option<HashMap<String, String>>,
    pub files: Option<HashMap<String, String>>,
    /// Also generate the `.envio/types.d.ts` and `Indexer.res` contents, so a
    /// caller can type-check handlers against the config's generated `indexer`
    /// surface, or assert on the generated ReScript.
    pub with_indexer_types: Option<bool>,
}

#[napi_derive::napi(object)]
pub struct FromUserApiResult {
    /// The public config JSON, the same shape `get_config_json` returns.
    pub config: String,
    /// The generated `.envio/types.d.ts`, present only when
    /// `with_indexer_types` was requested.
    pub indexer_types: Option<String>,
    /// The generated `Indexer.res`, present only when `with_indexer_types` was
    /// requested and the config isn't SVM (which has no ReScript surface).
    /// Same production codegen output, from the same parse.
    pub indexer_code: Option<String>,
}

fn serialize_config_result(config: anyhow::Result<SystemConfig>) -> napi::Result<String> {
    let system_config = config.map_err(|e| napi::Error::from_reason(format!("{e:#}")))?;
    system_config
        .to_public_config_json(false)
        .map_err(|e| napi::Error::from_reason(format!("Failed serializing config: {e}")))
}

#[derive(Default)]
#[napi_derive::napi(object)]
pub struct FromSubgraphOptions {
    /// Indexer name. subgraph.yaml has no name field, so the project directory
    /// supplies one.
    pub name: Option<String>,
    pub env: Option<HashMap<String, String>>,
    pub files: Option<HashMap<String, String>>,
    /// Directory the manifest's mapping paths resolve against.
    pub root: Option<String>,
}

/// `ports_served_here` are the ports servers in the calling process listen on:
/// the call blocks that process, so a subgraph's RPC endpoint on one of them
/// can't answer the parse's `eth_chainId`.
#[napi_derive::napi]
pub fn get_config_json(
    config_path: Option<String>,
    directory: Option<String>,
    ports_served_here: Option<Vec<u32>>,
) -> napi::Result<String> {
    let project_root = directory.unwrap_or_else(|| ".".to_string());
    let config = config_path
        .or_else(|| std::env::var("ENVIO_CONFIG").ok())
        .unwrap_or_else(|| "config.yaml".to_string());
    let project_paths = ParsedProjectPaths::new(&project_root, &config)
        .map_err(|e| napi::Error::from_reason(format!("Failed parsing project paths: {e}")))?;
    let ports: Vec<u16> = ports_served_here
        .unwrap_or_default()
        .into_iter()
        .filter_map(|port| u16::try_from(port).ok())
        .collect();
    serialize_config_result(crate::subgraph::with_ports_served_here(&ports, || {
        SystemConfig::parse_from_project_files(&project_paths)
    }))
}

/// Parses an inline indexer config the way a user's project would, without
/// consulting the filesystem or process environment. Schema text, interpolation
/// variables, and ABI/IDL file bodies are supplied explicitly so callers can use
/// this from any working directory. With `with_indexer_types`, also returns the
/// generated `.envio/types.d.ts` — the same TypeScript production codegen writes
/// — from the single parse, so a caller can type-check handlers against the
/// config's `indexer` surface without re-parsing.
#[napi_derive::napi]
pub fn from_user_api(
    yaml: String,
    options: Option<FromUserApiOptions>,
) -> napi::Result<FromUserApiResult> {
    let options = options.unwrap_or_default();
    let env = options.env.unwrap_or_default();
    let files = options.files.unwrap_or_default();
    let config = SystemConfig::parse_yaml(&yaml, options.schema.as_deref(), &env, &files, false)
        .map_err(|e| napi::Error::from_reason(format!("{e:#}")))?;

    let config_json = config
        .to_public_config_json(false)
        .map_err(|e| napi::Error::from_reason(format!("Failed serializing config: {e}")))?;

    let (indexer_types, indexer_code) = if options.with_indexer_types.unwrap_or(false) {
        let template = ProjectTemplate::from_config(&config).map_err(|e| {
            napi::Error::from_reason(format!("Failed generating indexer types: {e:#}"))
        })?;
        (
            Some(template.indexer_types_dts().to_string()),
            template.indexer_code().map(str::to_string),
        )
    } else {
        (None, None)
    };

    Ok(FromUserApiResult {
        config: config_json,
        indexer_types,
        indexer_code,
    })
}

/// A subgraph project's AssemblyScript file as the JavaScript that runs it.
/// Called by the subgraph runtime's load hook for every file it imports from
/// the project.
#[napi_derive::napi]
pub fn subgraph_file_to_javascript(
    source: String,
    path: String,
    legacy_nulls: bool,
) -> napi::Result<String> {
    crate::subgraph::assemblyscript::to_javascript(
        &source,
        std::path::Path::new(&path),
        legacy_nulls,
    )
    .map_err(|e| napi::Error::from_reason(format!("{e:#}")))
}

/// graph-ts' `crypto.keccak256`. ENS hashes a node on every event and again in
/// every replay round, and the JavaScript keccak was 15% of indexing CPU.
#[napi_derive::napi]
pub fn subgraph_keccak256(
    input: napi::bindgen_prelude::Uint8ArraySlice,
) -> napi::bindgen_prelude::Buffer {
    alloy_primitives::keccak256(&*input).to_vec().into()
}

/// For each data source (its mapping file and handlers), the handlers the
/// register pass reruns: those whose code can reach `DataSourceTemplate.create`,
/// and those that touch an entity type whose loaded state decides a create.
#[napi_derive::napi]
pub fn subgraph_register_handlers(
    mapping_files: Vec<String>,
    handlers: Vec<Vec<String>>,
) -> Vec<Vec<String>> {
    let sources: Vec<(std::path::PathBuf, Vec<String>)> = mapping_files
        .into_iter()
        .map(std::path::PathBuf::from)
        .zip(handlers)
        .collect();
    crate::subgraph::creates::register_handlers(&sources)
}

/// For each handler of the mapping, the templates whose generated class its
/// code surely reaches.
#[napi_derive::napi]
pub fn subgraph_sure_creates(
    mapping_file: String,
    handlers: Vec<String>,
    templates: Vec<String>,
) -> Vec<Vec<String>> {
    crate::subgraph::creates::sure_creates(
        std::path::Path::new(&mapping_file),
        &handlers,
        &templates,
    )
}

#[napi_derive::napi(object)]
pub struct BundledCodegenResult {
    /// Where the tree was written.
    pub output_dir: String,
    /// The files written, relative to `output_dir`.
    pub files: Vec<String>,
}

/// `graph codegen` without graph-cli: writes the generated tree for the
/// manifest, into `output_dir` or else where the mappings import it from.
#[napi_derive::napi]
pub fn subgraph_bundled_codegen(
    manifest_file: String,
    output_dir: Option<String>,
) -> napi::Result<BundledCodegenResult> {
    let manifest = std::path::Path::new(&manifest_file);
    let run = || -> anyhow::Result<BundledCodegenResult> {
        let output_dir = match output_dir {
            Some(dir) => std::path::PathBuf::from(dir),
            None => crate::subgraph::codegen::output_dir_for(
                manifest.parent().unwrap_or(std::path::Path::new(".")),
                manifest,
            )?,
        };
        let files = crate::subgraph::codegen::generate(manifest, &output_dir)?;
        Ok(BundledCodegenResult {
            output_dir: output_dir.display().to_string(),
            files,
        })
    };
    run().map_err(|e| napi::Error::from_reason(format!("{e:#}")))
}

#[napi_derive::napi(object)]
pub struct FilledGeneratedFile {
    /// Relative to the generated directory.
    pub file: String,
    /// The project-relative manifest that declares its data source, or the ABI
    /// file it was written from when no manifest does (`abi_name` set).
    pub source: String,
    /// Set when the file was written from the ABI of this name.
    pub abi_name: Option<String>,
    /// Set when the file was written from its data source's ABI, which now has
    /// this name rather than the data source's.
    pub renamed_from: Option<String>,
    /// The file was written from an ABI file no manifest names any more.
    pub undeclared: bool,
}

/// The `wanted` generated files that the project's other manifests declare,
/// then those whose ABI some manifest names, written into `output_dir` (see
/// `codegen::fill_from_manifests` and `codegen::fill_from_abi_names`).
#[napi_derive::napi]
pub fn subgraph_fill_generated(
    root: String,
    manifest_file: String,
    output_dir: String,
    wanted: Vec<String>,
) -> Vec<FilledGeneratedFile> {
    let root = std::fs::canonicalize(&root).unwrap_or_else(|_| std::path::PathBuf::from(&root));
    let root = root.as_path();
    let output_dir = std::path::Path::new(&output_dir);
    let own = std::fs::canonicalize(&manifest_file).ok();
    let others: Vec<std::path::PathBuf> = crate::subgraph::find_manifests(root)
        .into_iter()
        .map(|relative| root.join(relative))
        .chain(crate::subgraph::codegen::data_source_fragments(root))
        .filter(|manifest| std::fs::canonicalize(manifest).ok() != own)
        .collect();
    let relative = |path: &std::path::Path| {
        let path = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
        path.strip_prefix(root)
            .unwrap_or(&path)
            .display()
            .to_string()
    };
    let mut filled: Vec<FilledGeneratedFile> =
        crate::subgraph::codegen::fill_from_manifests(&others, root, output_dir, &wanted)
            .into_iter()
            .map(|(file, manifest)| FilledGeneratedFile {
                file,
                source: relative(&manifest),
                abi_name: None,
                renamed_from: None,
                undeclared: false,
            })
            .collect();
    let all: Vec<std::path::PathBuf> = std::iter::once(std::path::PathBuf::from(&manifest_file))
        .chain(others)
        .collect();
    filled.extend(
        crate::subgraph::codegen::fill_from_abi_names(&all, root, output_dir, &wanted)
            .into_iter()
            .map(|(file, abi_file)| FilledGeneratedFile {
                abi_name: std::path::Path::new(&file)
                    .file_stem()
                    .map(|stem| stem.to_string_lossy().to_string()),
                file,
                source: relative(&abi_file),
                renamed_from: None,
                undeclared: false,
            }),
    );
    filled.extend(
        crate::subgraph::codegen::fill_from_source_abis(&all, root, output_dir, &wanted)
            .into_iter()
            .map(|(file, abi_file, abi_name)| FilledGeneratedFile {
                file,
                source: relative(&abi_file),
                abi_name: None,
                renamed_from: Some(abi_name),
                undeclared: false,
            }),
    );
    filled.extend(
        crate::subgraph::codegen::fill_from_abi_files(&all, root, output_dir, &wanted)
            .into_iter()
            .map(|(file, abi_file)| FilledGeneratedFile {
                abi_name: std::path::Path::new(&file)
                    .file_stem()
                    .map(|stem| stem.to_string_lossy().to_string()),
                file,
                source: relative(&abi_file),
                renamed_from: None,
                undeclared: true,
            }),
    );
    filled
}

/// The packages of the workspace `root` sits in, name to directory.
#[napi_derive::napi]
pub fn subgraph_workspace_packages(root: String) -> std::collections::HashMap<String, String> {
    crate::subgraph::workspace::packages(std::path::Path::new(&root))
        .into_iter()
        .map(|(name, dir)| (name, dir.display().to_string()))
        .collect()
}

/// The package.json scripts that write a file a mapping imports, as `[name,
/// script]`, from the nearest package up from `dir`.
#[napi_derive::napi]
pub fn subgraph_scripts_writing(dir: String, needle: String) -> Vec<Vec<String>> {
    crate::subgraph::render::scripts_writing(std::path::Path::new(&dir), &needle)
        .into_iter()
        .map(|(name, script)| vec![name, script])
        .collect()
}

/// The directory that declares the workspace `root` sits in.
#[napi_derive::napi]
pub fn subgraph_workspace_root(root: String) -> Option<String> {
    crate::subgraph::workspace::root(std::path::Path::new(&root))
        .map(|dir| dir.display().to_string())
}

#[napi_derive::napi]
pub fn subgraph_missing_graph_cli_message(generated: String) -> String {
    crate::subgraph::missing_graph_cli_message(&generated)
}

#[napi_derive::napi]
pub fn subgraph_bundled_codegen_current(manifest_file: String, output_dir: String) -> bool {
    crate::subgraph::codegen::is_current(
        std::path::Path::new(&manifest_file),
        std::path::Path::new(&output_dir),
    )
}

/// Parses a subgraph project the same way `from_user_api` parses an envio one:
/// subgraph.yaml and its schema in memory, ABI bodies supplied through `files`,
/// no process environment. The returned config carries the translated manifest
/// under `subgraph`, which is what activates the subgraph runtime inside the
/// `envio` package.
///
/// The one thing read from disk is the mappings, and only when `root` names
/// where they are: the field selection follows what they touch. Without
/// `root` nothing is scanned — walking the process working directory would
/// make the config depend on where node happened to start.
#[napi_derive::napi]
pub fn from_subgraph(
    manifest: String,
    schema: String,
    options: Option<FromSubgraphOptions>,
) -> napi::Result<FromUserApiResult> {
    let options = options.unwrap_or_default();
    let env = options.env.unwrap_or_default();
    let files = options.files.unwrap_or_default();
    let name = options.name.unwrap_or_else(|| "subgraph".to_string());

    let mapping_sources = match &options.root {
        Some(root) => crate::subgraph::usage::gather(std::path::Path::new(root)),
        None => Vec::new(),
    };
    let root = options.root.unwrap_or_else(|| ".".to_string());
    let config = SystemConfig::parse_subgraph(
        &manifest,
        &schema,
        &name,
        &env,
        &files,
        &root,
        &mapping_sources,
    )
    .map_err(|e| napi::Error::from_reason(format!("{e:#}")))?;

    let config_json = config
        .to_public_config_json(false)
        .map_err(|e| napi::Error::from_reason(format!("Failed serializing config: {e}")))?;

    Ok(FromUserApiResult {
        config: config_json,
        indexer_types: None,
        indexer_code: None,
    })
}

#[napi_derive::napi]
pub fn load_ts(path: String) -> napi::Result<String> {
    crate::ts_loader::load(std::path::Path::new(&path)).map_err(napi::Error::from_reason)
}

#[napi_derive::napi]
pub fn ts_check_handler_format(path: String) -> napi::Result<()> {
    crate::ts_loader::check_handler_format(std::path::Path::new(&path))
        .map_err(napi::Error::from_reason)
}

#[napi_derive::napi]
pub fn ts_resolve_candidates(specifier: String, parent_url: Option<String>) -> Vec<String> {
    crate::ts_loader::resolve_candidates(&specifier, parent_url.as_deref())
}

#[napi_derive::napi]
pub fn ts_not_found_candidates(code: String, url: Option<String>, message: String) -> Vec<String> {
    crate::ts_loader::not_found_candidates(&code, url.as_deref(), &message)
}

/// Returns a JSON-encoded `Command` for JS to dispatch, or `None` when
/// Rust has handled the command end-to-end (help/version, codegen, init,
/// stop, docker up/down). The Node process then exits with code 0.
#[napi_derive::napi]
pub async fn run_cli(
    args: Vec<String>,
    envio_package_dir: Option<String>,
) -> napi::Result<Option<String>> {
    let mut full_args = vec!["envio".to_string()];
    full_args.extend(args);

    let matches = match CommandLineArgs::command()
        .version(crate::config_parsing::system_config::VERSION)
        .try_get_matches_from(&full_args)
    {
        Ok(m) => m,
        Err(e) if !e.use_stderr() => {
            // Help / version — clap writes to stdout; nothing for JS to do.
            print!("{e}");
            return Ok(None);
        }
        Err(e) => return Err(napi::Error::from_reason(format!("{e}"))),
    };

    let command_line_args = CommandLineArgs::from_arg_matches(&matches)
        .context("Failed parsing command line arguments")
        .map_err(|e| napi::Error::from_reason(format!("{e:#}")))?;

    let command = crate::executor::execute(command_line_args, envio_package_dir.as_deref())
        .await
        .map_err(|e| napi::Error::from_reason(format!("{e:#}")))?;

    match command {
        None => Ok(None),
        Some(cmd) => serde_json::to_string(&cmd)
            .map(Some)
            .map_err(|e| napi::Error::from_reason(format!("Failed serializing command: {e}"))),
    }
}
