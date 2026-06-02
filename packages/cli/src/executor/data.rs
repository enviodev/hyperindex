use anyhow::{anyhow, bail, Context, Result};
use serde_json::Value;
use std::time::Duration;

use crate::cli_args::clap_definitions::DataArgs;
use crate::data::{
    chain::{self, Chain},
    field_selection::Selection,
    toon,
    where_filter::WhereFilter,
};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(60);

pub async fn run(args: DataArgs) -> Result<()> {
    let token = resolve_api_token().ok_or_else(missing_token_error)?;
    if token.trim().is_empty() {
        return Err(missing_token_error());
    }

    let chain = chain::resolve(&args.chain)?;
    let selection = Selection::parse(&args.fields)?;
    let filter = WhereFilter::parse(args.where_filter.as_deref())?;
    let client = build_client(&chain, &token)?;

    if selection.known_height
        && !selection.has_data_fields()
        && filter.from_block.is_none()
        && filter.to_block_exclusive.is_none()
        && !filter.has_section_filters()
    {
        let height = client
            .get_height()
            .await
            .context("Failed fetching chain height")?;
        print!("{}", toon::render_height(height as i64));
        eprintln!();
        eprintln!("Chain {} is at height {}.", chain.display, height);
        return Ok(());
    }

    if !selection.has_data_fields() && !selection.known_height {
        bail!("No data fields requested. Pass at least one positional field.");
    }

    let query = filter.build_net_query(selection.build_net_field_selection())?;
    let response = client
        .get_arrow(&query)
        .await
        .context("Failed querying blockchain data")?;

    let mut out = toon::render_arrow_response(&selection, &response);

    let archive_height = response.archive_height.unwrap_or(0);

    if selection.known_height {
        out.push_str(&toon::render_archive_height(archive_height as i64));
    }

    print!("{out}");

    let next_block = response.next_block;
    let exhausted = matches!(filter.to_block_exclusive, Some(end) if next_block >= end)
        || next_block >= archive_height;

    if !exhausted {
        eprintln!();
        eprintln!(
            "Got a response up to block {next_block} (chain height: {archive_height}). \
             To get the next page, send the following query:"
        );
        eprintln!("  envio data {} \\", args.fields.join(" "));
        eprintln!("    --chain={} \\", chain.display);
        eprintln!(
            "    --where='{body}'",
            body = render_where_hint(&filter, next_block),
        );
    }

    Ok(())
}

fn build_client(chain: &Chain, token: &str) -> Result<hypersync_client::Client> {
    let user_agent = format!(
        "envio-data/{}",
        crate::config_parsing::system_config::VERSION,
    );
    hypersync_client::Client::new_with_agent(
        hypersync_client::ClientConfig {
            url: chain.base_url.clone(),
            api_token: token.to_string(),
            http_req_timeout_millis: REQUEST_TIMEOUT.as_millis() as u64,
            ..Default::default()
        },
        user_agent,
    )
    .context("Failed building blockchain data client")
}

fn render_where_hint(filter: &WhereFilter, next_block: u64) -> String {
    let mut parts: Vec<String> = Vec::new();

    let mut range = format!("number: {{ _gte: {next_block}");
    if let Some(end_excl) = filter.to_block_exclusive {
        let lte = end_excl.saturating_sub(1);
        range.push_str(&format!(", _lte: {lte}"));
    }
    range.push_str(" }");
    parts.push(format!("block: {{ {range} }}"));

    if let Some(s) = section_part("log", &filter.log_filters) {
        parts.push(s);
    }
    if let Some(s) = section_part("transaction", &filter.transaction_filters) {
        parts.push(s);
    }

    format!("{{ {} }}", parts.join(", "))
}

fn section_part(
    section: &str,
    filters: &[crate::data::where_filter::FieldFilter],
) -> Option<String> {
    if filters.is_empty() {
        return None;
    }
    let body: Vec<String> = filters
        .iter()
        .map(|f| {
            let v = if f.values.len() == 1 {
                short_value(&f.values[0])
            } else {
                short_value(&Value::Array(f.values.clone()))
            };
            format!("{name}: {v}", name = f.indexer_name)
        })
        .collect();
    Some(format!("{section}: {{ {} }}", body.join(", ")))
}

fn resolve_api_token() -> Option<String> {
    if let Ok(val) = std::env::var("ENVIO_API_TOKEN") {
        return Some(val);
    }
    use dotenvy::{EnvLoader, EnvSequence};
    EnvLoader::with_path(".env")
        .sequence(EnvSequence::InputOnly)
        .load()
        .ok()
        .and_then(|m| m.var("ENVIO_API_TOKEN").ok())
}

fn missing_token_error() -> anyhow::Error {
    anyhow!(
        "ENVIO_API_TOKEN is not set.\n\
         Set the ENVIO_API_TOKEN environment variable in your .env file.\n\
         Get a free API token at: https://envio.dev/app/api-tokens"
    )
}

fn short_value(v: &Value) -> String {
    serde_json::to_string(v).unwrap_or_else(|_| "<unprintable>".into())
}
