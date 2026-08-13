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
    /// requested. Same production codegen output, from the same parse.
    pub indexer_code: Option<String>,
}

fn serialize_config_result(config: anyhow::Result<SystemConfig>) -> napi::Result<String> {
    let system_config =
        config.map_err(|e| napi::Error::from_reason(format!("Config parse error: {e:#}")))?;
    system_config
        .to_public_config_json(false)
        .map_err(|e| napi::Error::from_reason(format!("Failed serializing config: {e}")))
}

#[napi_derive::napi]
pub fn get_config_json(
    config_path: Option<String>,
    directory: Option<String>,
) -> napi::Result<String> {
    let project_root = directory.unwrap_or_else(|| ".".to_string());
    let config = config_path
        .or_else(|| std::env::var("ENVIO_CONFIG").ok())
        .unwrap_or_else(|| "config.yaml".to_string());
    let project_paths = ParsedProjectPaths::new(&project_root, &config)
        .map_err(|e| napi::Error::from_reason(format!("Failed parsing project paths: {e}")))?;
    serialize_config_result(SystemConfig::parse_from_project_files(&project_paths))
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
        .map_err(|e| napi::Error::from_reason(format!("Config parse error: {e:#}")))?;

    let config_json = config
        .to_public_config_json(false)
        .map_err(|e| napi::Error::from_reason(format!("Failed serializing config: {e}")))?;

    let (indexer_types, indexer_code) = if options.with_indexer_types.unwrap_or(false) {
        let template = ProjectTemplate::from_config(&config).map_err(|e| {
            napi::Error::from_reason(format!("Failed generating indexer types: {e:#}"))
        })?;
        (
            Some(template.indexer_types_dts().to_string()),
            Some(template.indexer_code().to_string()),
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

#[napi_derive::napi(object)]
pub struct TransformTsResult {
    pub code: String,
    /// JSON source map, always emitted so handler stack traces point at the
    /// user's TypeScript rather than the stripped output.
    pub map: Option<String>,
}

/// Strips types from a TypeScript handler module and lowers the syntax Node
/// cannot execute directly (enums, namespaces, decorators, JSX). Called by the
/// module load hook that `HandlerLoader` registers.
#[napi_derive::napi]
pub fn transform_ts(filename: String, source: String) -> napi::Result<TransformTsResult> {
    use oxc::allocator::Allocator;
    use oxc::codegen::{Codegen, CodegenOptions};
    use oxc::parser::Parser;
    use oxc::semantic::SemanticBuilder;
    use oxc::span::SourceType;
    use oxc::transformer::{TransformOptions, Transformer};
    use std::path::Path;

    let path = Path::new(&filename);
    let source_type = SourceType::from_path(path).map_err(|_| {
        napi::Error::from_reason(format!("Unsupported handler file extension: {filename}"))
    })?;

    fn report(
        stage: &str,
        filename: &str,
        diagnostics: &[oxc::diagnostics::OxcDiagnostic],
    ) -> napi::Error {
        let message = diagnostics
            .iter()
            .map(|diagnostic| diagnostic.to_string())
            .collect::<Vec<_>>()
            .join("\n");
        napi::Error::from_reason(format!("Failed {stage} {filename}:\n{message}"))
    }

    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, &source, source_type).parse();
    if !parsed.diagnostics.is_empty() {
        return Err(report("parsing", &filename, &parsed.diagnostics));
    }

    let mut program = parsed.program;
    // `with_enum_eval` is what lets the transformer resolve enum member values;
    // without it, lowering an `enum` panics.
    let scoping = SemanticBuilder::new()
        .with_enum_eval(true)
        .build(&program)
        .semantic
        .into_scoping();
    let transformed = Transformer::new(&allocator, path, &TransformOptions::default())
        .build_with_scoping(scoping, &mut program);
    if !transformed.diagnostics.is_empty() {
        return Err(report("transforming", &filename, &transformed.diagnostics));
    }

    let generated = Codegen::new()
        .with_options(CodegenOptions {
            source_map_path: Some(path.to_path_buf()),
            ..CodegenOptions::default()
        })
        .build(&program);

    Ok(TransformTsResult {
        code: generated.code,
        map: generated.map.map(|map| map.to_json_string()),
    })
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
