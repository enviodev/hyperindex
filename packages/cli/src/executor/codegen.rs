use crate::{
    commands,
    config_parsing::system_config::SystemConfig,
    executor::{build_resolvers_command, Command, ResolversMode},
    project_paths::ParsedProjectPaths,
};
use anyhow::{Context, Result};

/// Rust codegen, then the resolver artefacts.
///
/// §11.2: codegen **always** emits `.envio/resolvers.json` and
/// `.envio/resolvers.graphql`, whether or not the project declares any. Always
/// emitting is what removes the "file missing" branch from the serve init
/// container and the build reporter — and for a project that does declare
/// them, this is where a name colliding with a generated one fails the build,
/// which is the place the user can act on it.
///
/// It has to come back as a `Command` rather than happening here: reading the
/// declarations means importing the user's TypeScript, and that needs Node.
pub async fn run_codegen(project_paths: &ParsedProjectPaths) -> Result<Command> {
    let config =
        SystemConfig::parse_from_project_files(project_paths).context("Failed parsing config")?;
    commands::codegen::run_codegen(&config)
        .await
        .context("Failed running codegen")?;
    build_resolvers_command(&config, ResolversMode::Manifest)
}
