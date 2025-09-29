use anyhow::Context;
use std::path::Path;

async fn execute_command(
    cmd: &str,
    args: Vec<&str>,
    current_dir: &Path,
) -> anyhow::Result<std::process::ExitStatus> {
    tokio::process::Command::new(cmd)
        .args(&args)
        .current_dir(current_dir)
        .stdin(std::process::Stdio::null()) //passes null on any stdinprompt
        .kill_on_drop(true) //needed so that dropped threads calling this will also drop
        //the child process
        .spawn()
        .context(format!(
            "Failed to spawn command {} {} at {} as child process",
            cmd,
            args.join(" "),
            current_dir.to_str().unwrap_or("bad_path")
        ))?
        .wait()
        .await
        .context(format!(
            "Failed to exit command {} {} at {} from child process",
            cmd,
            args.join(" "),
            current_dir.to_str().unwrap_or("bad_path")
        ))
}

async fn execute_command_with_env(
    cmd: &str,
    args: Vec<&str>,
    current_dir: &Path,
    envs: Vec<(&str, String)>,
) -> anyhow::Result<std::process::ExitStatus> {
    let mut command = tokio::process::Command::new(cmd);
    command
        .args(&args)
        .current_dir(current_dir)
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);

    for (key, val) in envs {
        command.env(key, val);
    }

    command
        .spawn()
        .context(format!(
            "Failed to spawn command {} {} at {} as child process",
            cmd,
            args.join(" "),
            current_dir.to_str().unwrap_or("bad_path")
        ))?
        .wait()
        .await
        .context(format!(
            "Failed to exit command {} {} at {} from child process",
            cmd,
            args.join(" "),
            current_dir.to_str().unwrap_or("bad_path")
        ))
}

pub mod rescript {
    use super::execute_command;
    use anyhow::Result;
    use std::path::Path;

    pub async fn build(path: &Path) -> Result<std::process::ExitStatus> {
        let args = vec!["rescript"];
        execute_command("pnpm", args, path).await
    }
}

pub mod codegen {
    use super::{execute_command, rescript};
    use crate::{
        config_parsing::system_config::SystemConfig, hbs_templating, template_dirs::TemplateDirs,
    };
    use anyhow::{self, Context, Result};
    use std::path::Path;

    use crate::project_paths::ParsedProjectPaths;
    use tokio::fs;

    pub async fn remove_files_except_git(directory: &Path) -> Result<()> {
        let mut entries = fs::read_dir(directory).await?;
        while let Some(entry) = entries.next_entry().await? {
            let file_type = entry.file_type().await?;
            let path = entry.path();

            if path.ends_with(".git") {
                continue;
            }

            if file_type.is_dir() {
                fs::remove_dir_all(&path).await?;
            } else {
                fs::remove_file(&path).await?;
            }
        }

        Ok(())
    }

    pub async fn check_and_install_pnpm(current_dir: &Path) -> Result<()> {
        // Check if pnpm is already installed
        let check_pnpm = execute_command("pnpm", vec!["--version"], current_dir).await;

        // If pnpm is not installed, run the installation command
        match check_pnpm {
            Ok(status) if status.success() => {
                println!("Package pnpm is already installed. Continuing...");
            }
            _ => {
                println!("Package pnpm is not installed. Installing now...");
                let args = vec!["install", "--global", "pnpm"];
                execute_command("npm", args, current_dir).await?;
            }
        }
        Ok(())
    }

    async fn pnpm_install(project_paths: &ParsedProjectPaths) -> Result<std::process::ExitStatus> {
        println!("Checking for pnpm package...");
        check_and_install_pnpm(&project_paths.generated).await?;

        execute_command(
            "pnpm",
            vec!["install", "--no-lockfile", "--prefer-offline"],
            &project_paths.generated,
        )
        .await?;
        execute_command(
            "pnpm",
            vec!["install", "--prefer-offline"],
            &project_paths.project_root,
        )
        .await
    }

    async fn run_post_codegen_command_sequence(
        project_paths: &ParsedProjectPaths,
    ) -> anyhow::Result<std::process::ExitStatus> {
        println!("Installing packages... ");
        let exit1 = pnpm_install(project_paths).await?;
        if !exit1.success() {
            return Ok(exit1);
        }

        println!("Generating HyperIndex code...");
        let exit3 = rescript::build(&project_paths.generated)
            .await
            .context("Failed running rescript build")?;
        if !exit3.success() {
            return Ok(exit3);
        }

        Ok(exit3)
    }

    pub async fn run_codegen(config: &SystemConfig) -> anyhow::Result<()> {
        let template_dirs = TemplateDirs::new();
        fs::create_dir_all(&config.parsed_project_paths.generated).await?;

        let template = hbs_templating::codegen_templates::ProjectTemplate::from_config(config)
            .context("Failed creating project template")?;

        template_dirs
            .get_codegen_static_dir()?
            .extract(&config.parsed_project_paths.generated)
            .context("Failed extracting static codegen files")?;

        template
            .generate_templates(&config.parsed_project_paths)
            .context("Failed generating dynamic codegen files")?;

        run_post_codegen_command_sequence(&config.parsed_project_paths)
            .await
            .context("Failed running post codegen command sequence")?;

        Ok(())
    }
}

pub mod start {
    use super::{execute_command, execute_command_with_env};
    use crate::config_parsing::system_config::SystemConfig;
    use crate::utils::token_manager::{TokenManager, HYPERSYNC_ACCOUNT, SERVICE_NAME};
    use anyhow::anyhow;
    use std::fs;

    pub async fn start_indexer(
        config: &SystemConfig,
        should_open_hasura: bool,
    ) -> anyhow::Result<()> {
        if should_open_hasura {
            println!("Opening Hasura console at http://localhost:8080 ...");
            if open::that_detached("http://localhost:8080").is_err() {
                println!(
                    "Unable to open http://localhost:8080 in your browser automatically for you. \
                     You can open that link yourself to view hasura"
                );
            }
        }
        let cmd = "npm";
        let args = vec!["run", "start"];

        // Determine whether to inject ENVIO_API_TOKEN from vault
        let project_root = &config.parsed_project_paths.project_root;
        let env_path = project_root.join(".env");
        let mut should_inject_token = true;

        if let Ok(contents) = fs::read_to_string(&env_path) {
            // If .env contains an ENVIO_API_TOKEN definition, do not inject
            if contents
                .lines()
                .any(|l| l.trim_start().starts_with("ENVIO_API_TOKEN="))
            {
                should_inject_token = false;
            }
        }

        let exit = if should_inject_token {
            // Attempt to load HyperSync token from vault and inject if present
            match TokenManager::new(SERVICE_NAME, HYPERSYNC_ACCOUNT).get_token() {
                Ok(Some(token)) => {
                    execute_command_with_env(
                        cmd,
                        args,
                        &config.parsed_project_paths.generated,
                        vec![("ENVIO_API_TOKEN", token)],
                    )
                    .await?
                }
                _ => {
                    // No token available; run without injection
                    execute_command(cmd, args, &config.parsed_project_paths.generated).await?
                }
            }
        } else {
            // .env already defines ENVIO_API_TOKEN; run without injection
            execute_command(cmd, args, &config.parsed_project_paths.generated).await?
        };

        if !exit.success() {
            return Err(anyhow!(
                "Indexer crashed. For more details see the error logs above the TUI. Can't find \
                 them? Restart the indexer with the 'TUI_OFF=true pnpm start' command."
            ));
        }
        println!(
            "\nIndexer has successfully finished processing all events on all chains. Exiting \
             process."
        );
        Ok(())
    }
}
pub mod docker {
    use super::execute_command;
    use crate::config_parsing::system_config::SystemConfig;

    pub async fn docker_compose_up_d(
        config: &SystemConfig,
    ) -> anyhow::Result<std::process::ExitStatus> {
        let cmd = "docker";
        let args = vec!["compose", "up", "-d"];
        let current_dir = &config.parsed_project_paths.generated;

        execute_command(cmd, args, current_dir).await
    }
    pub async fn docker_compose_down_v(
        config: &SystemConfig,
    ) -> anyhow::Result<std::process::ExitStatus> {
        let cmd = "docker";
        let args = vec!["compose", "down", "-v"];
        let current_dir = &config.parsed_project_paths.generated;

        execute_command(cmd, args, current_dir).await
    }
}

pub mod db_migrate {
    use anyhow::{anyhow, Context};

    use std::process::ExitStatus;

    use super::execute_command;
    use crate::{config_parsing::system_config::SystemConfig, persisted_state::PersistedState};

    pub async fn run_up_migrations(
        config: &SystemConfig,
        persisted_state: &PersistedState,
    ) -> anyhow::Result<()> {
        let args = vec!["db-up"];
        let current_dir = &config.parsed_project_paths.generated;
        let exit = execute_command("pnpm", args, current_dir).await?;

        if !exit.success() {
            return Err(anyhow!("Failed to run db migrations"));
        }

        persisted_state
            .upsert_to_db()
            .await
            .context("Failed to upsert persisted state table")?;
        Ok(())
    }

    pub async fn run_drop_schema(config: &SystemConfig) -> anyhow::Result<ExitStatus> {
        let args = vec!["db-down"];
        let current_dir = &config.parsed_project_paths.generated;
        execute_command("pnpm", args, current_dir).await
    }

    pub async fn run_db_setup(
        config: &SystemConfig,
        persisted_state: &PersistedState,
    ) -> anyhow::Result<()> {
        let args = vec!["db-setup"];
        let current_dir = &config.parsed_project_paths.generated;
        let exit = execute_command("pnpm", args, current_dir).await?;

        if !exit.success() {
            return Err(anyhow!("Failed to run db migrations"));
        }

        persisted_state
            .upsert_to_db()
            .await
            .context("Failed to upsert persisted state table")?;
        Ok(())
    }
}

pub mod benchmark {
    use super::execute_command;
    use crate::config_parsing::system_config::SystemConfig;
    use anyhow::{anyhow, Result};

    pub async fn print_summary(config: &SystemConfig) -> Result<()> {
        let args = vec!["print-benchmark-summary"];
        let current_dir = &config.parsed_project_paths.generated;
        let exit = execute_command("pnpm", args, current_dir).await?;

        if !exit.success() {
            return Err(anyhow!("Failed printing benchmark summary"));
        }

        Ok(())
    }
}

/// manages the login flow to Envio via GitHub OAuth.
pub mod login {
    use crate::utils::token_manager::{TokenManager, JWT_ACCOUNT, SERVICE_NAME};
    use anyhow::{anyhow, Context, Result};
    use open;
    use reqwest::StatusCode;
    use serde::{Deserialize, Serialize};
    use std::time::Duration;
    use tokio::time::sleep;

    /// Default UI/API base URL. Change this constant to point to your deployment.
    pub const AUTH_BASE_URL: &str = "https://envio.dev";

    fn get_api_base_url() -> String {
        // Allow override via ENVIO_API_URL, otherwise use the constant above.
        std::env::var("ENVIO_API_URL").unwrap_or_else(|_| AUTH_BASE_URL.to_string())
    }

    /// Default UI/API base URL. Change this constant to point to your deployment.
    pub const HYPERSYNC_TOKEN_API_URL: &str = "https://hypersync-tokens.hyperquery.xyz";

    #[derive(Debug, Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct CliAuthSession {
        code: String,
        auth_url: String,
        expires_in: i32,
    }

    #[derive(Debug, Deserialize)]
    struct CliAuthStatus {
        completed: bool,
        error: Option<String>,
        token: Option<String>,
    }

    #[derive(Debug, Serialize)]
    struct EmptyBody {}

    pub async fn run_login() -> Result<()> {
        let base = get_api_base_url();
        let client = reqwest::Client::new();

        // 1) Create a CLI auth session
        let create_url = format!("{}/api/auth/cli-session", base);
        let session: CliAuthSession = client
            .post(&create_url)
            .json(&EmptyBody {})
            .send()
            .await
            .with_context(|| format!("Failed to POST {}", create_url))?
            .error_for_status()
            .with_context(|| format!("Non-200 from {}", create_url))?
            .json()
            .await
            .context("Failed to decode CLI session response")?;

        println!(
            "Opening browser for authentication...\nIf it doesn't open, visit: {}",
            session.auth_url
        );
        let _ = open::that_detached(&session.auth_url);

        // 2) Poll for completion
        let poll_url = format!("{}/api/auth/cli-session?code={}", base, session.code);
        let poll_time_seconds = 2;
        let poll_interval = Duration::from_secs(poll_time_seconds);
        // Add a small grace window to handle cold starts or UI recompiles wiping in-memory state
        let extra_grace_attempts = 15; // ~30s grace
        let max_attempts =
            (session.expires_in.max(0) as u64) / poll_time_seconds + extra_grace_attempts;

        // Give the UI a brief warm-up before first poll
        sleep(Duration::from_secs(poll_time_seconds)).await;

        let mut consecutive_not_found = 0u32;

        for _ in 0..max_attempts {
            sleep(poll_interval).await;

            let resp = match client.get(&poll_url).send().await {
                Ok(r) => r,
                Err(_) => {
                    // transient network error; try again
                    continue;
                }
            };

            if resp.status() == StatusCode::NOT_FOUND {
                consecutive_not_found += 1;
                // Keep polling; in-memory session store may not be ready yet
                if consecutive_not_found % 10 == 1 {
                    // Print a lightweight status occasionally
                    eprintln!("Waiting for session to become available...");
                }
                continue;
            } else {
                consecutive_not_found = 0;
            }

            if resp.status().is_success() {
                let status: CliAuthStatus = match resp.json().await {
                    Ok(s) => s,
                    Err(_) => continue,
                };

                if let Some(err) = status.error {
                    if !err.is_empty() {
                        return Err(anyhow!("authentication error: {}", err));
                    }
                }

                if status.completed {
                    if let Some(token) = status.token {
                        let tm = TokenManager::new(SERVICE_NAME, JWT_ACCOUNT);
                        if let Err(e) = tm.store_token(&token) {
                            eprintln!("Warning: failed to store token in keyring: {}", e);
                        }

                        println!("Successfully logged in to Envio.");

                        return Ok(());
                    }
                }
            }
        }

        Err(anyhow!("authentication timed out"))
    }

    pub fn get_stored_jwt() -> Result<Option<String>> {
        TokenManager::new(SERVICE_NAME, JWT_ACCOUNT).get_token()
    }
}

/// manages the flow of getting hypersync api tokens
pub mod hypersync {
    use super::login::{get_stored_jwt, HYPERSYNC_TOKEN_API_URL};
    use crate::utils::token_manager::{TokenManager, HYPERSYNC_ACCOUNT, SERVICE_NAME};
    use anyhow::{anyhow, Context, Result};
    use reqwest::StatusCode;
    use serde::{Deserialize, Serialize};

    fn get_hypersync_tokens_base_url() -> String {
        // Allow override specific for tokens service; else fall back to the constant
        std::env::var("ENVIO_HYPERSYNC_TOKENS_URL")
            .unwrap_or_else(|_| HYPERSYNC_TOKEN_API_URL.to_string())
    }

    #[derive(Debug, Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct TokenResponse {
        #[serde(rename = "user_token")]
        user_token: String,
    }

    async fn create_user_if_needed(client: &reqwest::Client, base: &str, jwt: &str) -> Result<()> {
        let url = format!("{}/user/create", base);
        let resp = client
            .post(&url)
            .header("authorization", format!("Bearer {}", jwt))
            .header("content-type", "application/json")
            .send()
            .await
            .with_context(|| format!("POST {} failed", url))?;
        if resp.status() == StatusCode::OK || resp.status() == StatusCode::CONFLICT {
            Ok(())
        } else {
            Err(anyhow!("Failed to create user: {}", resp.status()))
        }
    }

    async fn create_api_token(client: &reqwest::Client, base: &str, jwt: &str) -> Result<String> {
        #[derive(Serialize)]
        struct Body {
            enable_active_networks: bool,
        }
        let url = format!("{}/token/create", base);
        let resp = client
            .post(&url)
            .header("authorization", format!("Bearer {}", jwt))
            .header("content-type", "application/json")
            .json(&Body {
                enable_active_networks: true,
            })
            .send()
            .await
            .with_context(|| format!("POST {} failed", url))?;
        if resp.status().is_success() || resp.status() == StatusCode::CONFLICT {
            // Accept JSON or plain text
            let bytes = resp.bytes().await.context("Read token response body")?;
            let body_str = std::str::from_utf8(&bytes).unwrap_or("").trim();
            if body_str.starts_with('{') {
                let json: TokenResponse =
                    serde_json::from_slice(&bytes).context("Decode token response")?;
                Ok(json.user_token)
            } else if !body_str.is_empty() {
                Ok(body_str.to_string())
            } else {
                Err(anyhow!("Empty token response"))
            }
        } else {
            Err(anyhow!("Failed to create token: {}", resp.status()))
        }
    }

    async fn list_api_tokens(
        client: &reqwest::Client,
        base: &str,
        jwt: &str,
    ) -> Result<Vec<String>> {
        #[derive(Debug, serde::Deserialize)]
        struct UserTokensResponse {
            tokens: Vec<String>,
        }

        let url = format!("{}/token/get-user-tokens", base);
        let resp = client
            .get(&url)
            .header("authorization", format!("Bearer {}", jwt))
            .header("content-type", "application/json")
            .send()
            .await
            .with_context(|| format!("GET {} failed", url))?;

        if resp.status().is_success() {
            let body: UserTokensResponse =
                resp.json().await.context("Decode user tokens response")?;
            Ok(body.tokens)
        } else {
            Ok(vec![])
        }
    }

    fn store_api_token(token: &str) -> Result<()> {
        TokenManager::new(SERVICE_NAME, HYPERSYNC_ACCOUNT).store_token(token)
    }

    /// get the hypersync api token from the keyring or the api
    ///     doesn't perform any login actions if the user is not logged in.
    pub async fn get_hypersync_token() -> Result<Option<String>> {
        // 1) If we already have a token in keyring, use it
        if let Some(existing) = TokenManager::new(SERVICE_NAME, HYPERSYNC_ACCOUNT).get_token()? {
            return Ok(Some(existing));
        }

        // 2) If we have a JWT, try to list existing tokens without creating a new one
        let jwt = match get_stored_jwt()? {
            Some(t) => t,
            None => return Ok(None), // Not logged in; do not login or provision
        };

        let base = get_hypersync_tokens_base_url();
        let client = reqwest::Client::new();
        let tokens = list_api_tokens(&client, &base, &jwt)
            .await
            .unwrap_or_default();
        if let Some(token) = tokens.get(0) {
            store_api_token(token)?;
            return Ok(Some(token.clone()));
        }
        Ok(None)
    }

    /// provision a new hypersync api token
    ///     this will create a new user if needed and create a new token
    ///     this will also store the token in the keyring
    pub async fn provision_and_get_token() -> Result<String> {
        let base = get_hypersync_tokens_base_url();
        let jwt = match get_stored_jwt()? {
            Some(t) => t,
            None => super::login::run_login().await.and_then(|_| {
                super::login::get_stored_jwt()?.ok_or_else(|| anyhow!("JWT missing after login"))
            })?,
        };

        let client = reqwest::Client::new();
        create_user_if_needed(&client, &base, &jwt).await?;

        // Prefer existing tokens; create only if none exist
        let mut selected: Option<String> = match list_api_tokens(&client, &base, &jwt).await {
            Ok(tokens) if !tokens.is_empty() => Some(tokens[0].clone()),
            _ => None,
        };

        if selected.is_none() {
            selected = Some(create_api_token(&client, &base, &jwt).await?);
        }

        let api_token = selected.expect("token must be set");
        store_api_token(&api_token)?;
        Ok(api_token)
    }

    pub async fn connect() -> Result<()> {
        let api_token = provision_and_get_token().await;

        match api_token {
            Ok(_token) => {
                println!("Token: {}", _token);
                println!("Successfully authenticated with HyperSync");
            }
            Err(e) => {
                eprintln!("Failed to authenticate with HyperSync: {}", e);
            }
        }

        Ok(())
    }
}

pub mod logout {
    use crate::utils::token_manager::{TokenManager, HYPERSYNC_ACCOUNT, JWT_ACCOUNT, SERVICE_NAME};
    use anyhow::Result;

    pub async fn run_logout() -> Result<()> {
        let jwt_tm = TokenManager::new(SERVICE_NAME, JWT_ACCOUNT);
        let hs_tm = TokenManager::new(SERVICE_NAME, HYPERSYNC_ACCOUNT);
        let _ = jwt_tm.clear_token();
        let _ = hs_tm.clear_token();
        println!("Logged out and cleared stored credentials.");
        Ok(())
    }
}
