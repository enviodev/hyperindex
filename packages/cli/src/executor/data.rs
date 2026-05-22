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
    let token = std::env::var("ENVIO_API_TOKEN").map_err(|_| missing_token_error())?;
    if token.trim().is_empty() {
        return Err(missing_token_error());
    }

    let chain = chain::resolve(&args.chain)?;
    let selection = Selection::parse(chain.kind, &args.fields)?;
    let filter = WhereFilter::parse(chain.kind, args.where_filter.as_deref())?;

    let client = reqwest::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .context("Failed building HTTP client")?;

    // Fast path: only `knownHeight` requested with no filters → hit /height.
    if selection.known_height
        && !selection.has_data_fields()
        && filter.from_block.is_none()
        && filter.to_block_exclusive.is_none()
        && !filter.has_section_filters()
    {
        let height = fetch_height(&client, &chain, &token).await?;
        print!("{}", toon::render_height(height));
        eprintln!();
        eprintln!("Chain {} is at height {}.", chain.display, height);
        return Ok(());
    }

    if !selection.has_data_fields() && !selection.known_height {
        bail!("No data fields requested. Pass at least one positional field.");
    }

    let body = filter.build_query_body(selection.build_field_selection());
    let response = post_query(&client, &chain, &token, &body).await?;

    let mut out = toon::render_response(&selection, &response);

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
            "    --where=\"\n{body}\n  \"",
            body = render_where_hint(chain.kind, &filter, next_block),
        );
    }

    Ok(())
}

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
    let mut out = String::new();
    out.push_str("      block:\n");
    out.push_str(&format!("        {range_field}:\n"));
    out.push_str(&format!("          _gte: {next_block}\n"));
    if let Some(end_excl) = filter.to_block_exclusive {
        let lte = end_excl.saturating_sub(1);
        out.push_str(&format!("          _lte: {lte}\n"));
    }
    render_section_block(&mut out, "log", &filter.log_filters);
    render_section_block(&mut out, "transaction", &filter.transaction_filters);
    render_section_block(&mut out, "receipt", &filter.receipt_filters);
    out.trim_end().to_string()
}

fn render_section_block(
    out: &mut String,
    section: &str,
    filters: &[crate::data::where_filter::FieldFilter],
) {
    if filters.is_empty() {
        return;
    }
    out.push_str(&format!("      {section}:\n"));
    for f in filters {
        let v = if f.values.len() == 1 {
            short_value(&f.values[0])
        } else {
            short_value(&Value::Array(f.values.clone()))
        };
        out.push_str(&format!("        {name}: {v}\n", name = f.indexer_name));
    }
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
