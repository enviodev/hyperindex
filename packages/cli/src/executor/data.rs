use anyhow::{anyhow, bail, Context, Result};
use serde_json::Value;
use std::time::Duration;

use crate::cli_args::clap_definitions::DataArgs;
use crate::data::{
    chain::{self, Chain, ChainKind},
    field_selection::Selection,
    toon,
    where_filter::WhereFilter,
};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(60);

pub async fn run(args: DataArgs) -> Result<()> {
    let token = std::env::var("ENVIO_API_TOKEN").map_err(|_| missing_token_error())?;
    if token.trim().is_empty() {
        return Err(missing_token_error());
    }

    let chain = chain::resolve(&args.chain)?;
    let selection = Selection::parse(chain.kind, &args.fields)?;
    let filter = WhereFilter::parse(chain.kind, args.where_filter.as_deref())?;

    match chain.kind {
        ChainKind::Evm => run_evm(&args, &chain, &token, &selection, &filter).await,
        ChainKind::Fuel => run_fuel(&args, &chain, &token, &selection, &filter).await,
    }
}

fn build_native_client(chain: &Chain, token: &str) -> Result<hypersync_client::Client> {
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

async fn run_evm(
    args: &DataArgs,
    chain: &Chain,
    token: &str,
    selection: &Selection,
    filter: &WhereFilter,
) -> Result<()> {
    let client = build_native_client(chain, token)?;

    // Fast path: only `knownHeight` requested with no filters -> hit /height.
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

    let net_fs = selection.build_net_field_selection();
    let query = filter.build_net_query(net_fs)?;
    let response = client
        .get(&query)
        .await
        .context("Failed querying blockchain data")?;

    let mut out = toon::render_query_response(selection, &response);

    let archive_height = response.archive_height.unwrap_or(0) as i64;

    if selection.known_height {
        out.push_str(&toon::render_archive_height(archive_height));
    }

    print!("{out}");

    let next_block = response.next_block;
    eprintln!();
    eprintln!("archive_height: {archive_height}");
    eprintln!("next_block: {next_block}");

    let exhausted = matches!(filter.to_block_exclusive, Some(end) if next_block >= end)
        || (next_block as i64) >= archive_height;

    if exhausted {
        eprintln!();
        eprintln!("Done — next_block ({next_block}) reached the end of the requested range.");
    } else {
        eprintln!();
        eprintln!("Next page:");
        eprintln!("  envio data {} \\", args.fields.join(" "));
        eprintln!("    --chain={} \\", chain.display);
        eprintln!(
            "    --where='{body}'",
            body = render_where_hint(chain.kind, filter, next_block),
        );
    }

    Ok(())
}

async fn run_fuel(
    args: &DataArgs,
    chain: &Chain,
    token: &str,
    selection: &Selection,
    filter: &WhereFilter,
) -> Result<()> {
    let client = reqwest::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .context("Failed building HTTP client")?;

    // Fast path: only `knownHeight` requested with no filters -> hit /height.
    if selection.known_height
        && !selection.has_data_fields()
        && filter.from_block.is_none()
        && filter.to_block_exclusive.is_none()
        && !filter.has_section_filters()
    {
        let height = fetch_height(&client, chain, token).await?;
        print!("{}", toon::render_height(height));
        eprintln!();
        eprintln!("Chain {} is at height {}.", chain.display, height);
        return Ok(());
    }

    if !selection.has_data_fields() && !selection.known_height {
        bail!("No data fields requested. Pass at least one positional field.");
    }

    let body = filter.build_query_body(selection.build_field_selection());
    let response = post_query(&client, chain, token, &body).await?;

    let mut out = toon::render_response(selection, &response);

    let archive_height = response
        .get("archive_height")
        .and_then(Value::as_i64)
        .unwrap_or(0);

    if selection.known_height {
        out.push_str(&toon::render_archive_height(archive_height));
    }

    print!("{out}");

    let next_block = response
        .get("next_block")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    eprintln!();
    eprintln!("archive_height: {archive_height}");
    eprintln!("next_block: {next_block}");

    let exhausted = matches!(filter.to_block_exclusive, Some(end) if next_block >= end)
        || (next_block as i64) >= archive_height;

    if exhausted {
        eprintln!();
        eprintln!("Done — next_block ({next_block}) reached the end of the requested range.");
    } else {
        eprintln!();
        eprintln!("Next page:");
        eprintln!("  envio data {} \\", args.fields.join(" "));
        eprintln!("    --chain={} \\", chain.display);
        eprintln!(
            "    --where='{body}'",
            body = render_where_hint(chain.kind, filter, next_block),
        );
    }

    Ok(())
}

/// JSON5-style one-liner that the user can copy-paste back into `--where`.
fn render_where_hint(
    kind: crate::data::chain::ChainKind,
    filter: &WhereFilter,
    next_block: u64,
) -> String {
    use crate::data::chain::ChainKind;
    let range_field = match kind {
        ChainKind::Evm => "number",
        ChainKind::Fuel => "height",
    };

    let mut parts: Vec<String> = Vec::new();

    let mut range = format!("{range_field}: {{ _gte: {next_block}");
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
    if let Some(s) = section_part("receipt", &filter.receipt_filters) {
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

fn missing_token_error() -> anyhow::Error {
    anyhow!(
        "ENVIO_API_TOKEN is not set.\n\
         Create one at https://envio.dev/app/api-tokens\n\
         Then run: export ENVIO_API_TOKEN=<your-token>"
    )
}

async fn fetch_height(client: &reqwest::Client, chain: &Chain, token: &str) -> Result<i64> {
    let url = format!("{}/height", chain.base_url);
    let resp = client
        .get(&url)
        .bearer_auth(token)
        .send()
        .await
        .with_context(|| format!("Failed calling {url}"))?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .with_context(|| format!("Failed reading body from {url}"))?;
    if !status.is_success() {
        bail!("{url} returned {status}: {text}");
    }
    let v: Value = serde_json::from_str(&text)
        .with_context(|| format!("Failed parsing JSON from {url}: {text}"))?;
    v.get("height")
        .and_then(Value::as_i64)
        .ok_or_else(|| anyhow!("Response from {url} had no `height`: {text}"))
}

async fn post_query(
    client: &reqwest::Client,
    chain: &Chain,
    token: &str,
    body: &Value,
) -> Result<Value> {
    let url = format!("{}/query", chain.base_url);
    let resp = client
        .post(&url)
        .bearer_auth(token)
        .json(body)
        .send()
        .await
        .with_context(|| format!("Failed calling {url}"))?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .with_context(|| format!("Failed reading body from {url}"))?;
    if !status.is_success() {
        bail!(
            "{url} returned {status}.\n\
             Request body: {body}\n\
             Response: {text}",
            body = serde_json::to_string(body).unwrap_or_else(|_| "<unprintable>".into()),
        );
    }
    serde_json::from_str(&text).with_context(|| format!("Failed parsing JSON from {url}: {text}"))
}

fn short_value(v: &Value) -> String {
    serde_json::to_string(v).unwrap_or_else(|_| "<unprintable>".into())
}
