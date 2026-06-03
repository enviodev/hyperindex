use anyhow::{anyhow, bail, Context, Result};
use serde_json::Value;
use std::time::Duration;

use crate::cli_args::clap_definitions::DataArgs;
use crate::data::{
    block_by_timestamp,
    chain::{self, Chain},
    client_filter,
    field_selection::Selection,
    mapping::Section,
    toon,
    where_filter::{ClientFilter, Cond, FieldFilter, WhereFilter},
};

enum PaginationState {
    RangeDone,
    ReachedHead,
    MorePages,
}

pub async fn run(args: DataArgs) -> Result<()> {
    let token = resolve_api_token().ok_or_else(missing_token_error)?;

    let chain = chain::resolve(&args.chain)?;
    let selection = Selection::parse(&args.fields)?;
    let mut filter = WhereFilter::parse(args.where_filter.as_deref())?;
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
        print!("{}", toon::render_height(height));
        eprintln!();
        eprintln!("Chain {} is at height {}.", chain.display, height);
        return Ok(());
    }

    if !selection.has_data_fields() && !selection.known_height {
        bail!("No data fields requested. Pass at least one positional field.");
    }

    block_by_timestamp::apply(&mut filter, &client).await?;
    filter.ensure_non_empty_range()?;

    let field_selection = selection.build_net_field_selection_with(&filter.client_filter_fields());
    let query = filter.build_net_query(field_selection)?;
    let response = client
        .get_arrow(&query)
        .await
        .context("Failed querying blockchain data")?;

    let masks = client_filter::compute_masks(&response, &filter.client_filters)?;
    let mut out = toon::render_arrow_response(&selection, &response, &masks);

    let archive_height = response.archive_height.unwrap_or(0);

    if selection.known_height {
        out.push_str(&toon::render_height(archive_height));
    }

    print!("{out}");

    let next_block = response.next_block;
    let state = if matches!(filter.to_block_exclusive, Some(end) if next_block >= end) {
        PaginationState::RangeDone
    } else if next_block >= archive_height {
        PaginationState::ReachedHead
    } else {
        PaginationState::MorePages
    };

    match state {
        PaginationState::RangeDone => {}
        PaginationState::ReachedHead => {
            eprintln!();
            eprintln!(
                "Reached the chain head at block {next_block}. \
                 Rerun the following command later to fetch newly available data:"
            );
            print_next_command(&args, &chain, &filter, next_block);
        }
        PaginationState::MorePages => {
            eprintln!();
            eprintln!(
                "Got a response up to block {next_block}. \
                 To get the next page, run the following command:"
            );
            print_next_command(&args, &chain, &filter, next_block);
        }
    }

    Ok(())
}

fn print_next_command(args: &DataArgs, chain: &Chain, filter: &WhereFilter, next_block: u64) {
    eprintln!("  envio data {} \\", args.fields.join(" "));
    eprintln!("    --chain={} \\", chain.display);
    eprintln!(
        "    --where='{body}'",
        body = render_where_hint(filter, next_block),
    );
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
            http_req_timeout_millis: Duration::from_secs(60).as_millis() as u64,
            ..Default::default()
        },
        user_agent,
    )
    .context("Failed building blockchain data client")
}

fn render_where_hint(filter: &WhereFilter, next_block: u64) -> String {
    let mut block: Vec<String> = Vec::new();
    let mut transaction: Vec<String> = Vec::new();
    let mut log: Vec<String> = Vec::new();

    let mut range = format!("number: {{ _gte: {next_block}");
    if let Some(end_excl) = filter.to_block_exclusive {
        let lte = end_excl.saturating_sub(1);
        range.push_str(&format!(", _lte: {lte}"));
    }
    // A `block.number` set scans [min, max] and drops the rest client-side, so
    // carry the set forward to keep filtering the same blocks across pages.
    if let Some(set) = block_number_set(filter) {
        range.push_str(&format!(
            ", _in: {}",
            json_string(&Value::Array(set.to_vec()))
        ));
    }
    range.push_str(" }");
    block.push(range);

    for f in &filter.server_filters {
        let entry = render_server_field(f);
        match f.field.section() {
            Section::Block => block.push(entry),
            Section::Transaction => transaction.push(entry),
            Section::Log => log.push(entry),
        }
    }
    for c in &filter.client_filters {
        if is_block_number(c) {
            continue;
        }
        let entry = render_client_field(c);
        match c.field.section() {
            Section::Block => block.push(entry),
            Section::Transaction => transaction.push(entry),
            Section::Log => log.push(entry),
        }
    }

    let parts: Vec<String> = [("block", block), ("transaction", transaction), ("log", log)]
        .into_iter()
        .filter(|(_, entries)| !entries.is_empty())
        .map(|(name, entries)| format!("{name}: {{ {} }}", entries.join(", ")))
        .collect();
    format!("{{ {} }}", parts.join(", "))
}

fn is_block_number(c: &ClientFilter) -> bool {
    c.field.section() == Section::Block && c.field.camel_name() == "number"
}

fn block_number_set(filter: &WhereFilter) -> Option<&[Value]> {
    filter
        .client_filters
        .iter()
        .find_map(|c| match c.conds.as_slice() {
            [Cond::In(vals)] if is_block_number(c) => Some(vals.as_slice()),
            _ => None,
        })
}

fn render_server_field(f: &FieldFilter) -> String {
    let v = if f.values.len() == 1 {
        json_string(&f.values[0])
    } else {
        json_string(&Value::Array(f.values.clone()))
    };
    format!("{name}: {v}", name = f.field.camel_name())
}

fn render_client_field(c: &ClientFilter) -> String {
    let name = c.field.camel_name();
    if let [Cond::In(vals)] = c.conds.as_slice() {
        let v = if vals.len() == 1 {
            json_string(&vals[0])
        } else {
            json_string(&Value::Array(vals.clone()))
        };
        return format!("{name}: {v}");
    }
    let ops: Vec<String> = c
        .conds
        .iter()
        .map(|cond| match cond {
            Cond::In(vals) if vals.len() == 1 => format!("_eq: {}", json_string(&vals[0])),
            Cond::In(vals) => format!("_in: {}", json_string(&Value::Array(vals.clone()))),
            Cond::Cmp(op, v) => format!("{}: {}", op.as_str(), json_string(v)),
        })
        .collect();
    format!("{name}: {{ {} }}", ops.join(", "))
}

fn json_string(v: &Value) -> String {
    serde_json::to_string(v).unwrap_or_else(|_| "<unprintable>".into())
}

fn resolve_api_token() -> Option<String> {
    let from_env = std::env::var("ENVIO_API_TOKEN").ok();
    let from_dotenv = || {
        use dotenvy::{EnvLoader, EnvSequence};
        EnvLoader::with_path(".env")
            .sequence(EnvSequence::InputOnly)
            .load()
            .ok()
            .and_then(|m| m.var("ENVIO_API_TOKEN").ok())
    };
    from_env
        .or_else(from_dotenv)
        .filter(|s| !s.trim().is_empty())
}

fn missing_token_error() -> anyhow::Error {
    anyhow!(
        "ENVIO_API_TOKEN is not set.\n\
         Set the ENVIO_API_TOKEN environment variable in your .env file.\n\
         Get a free API token at: https://envio.dev/app/api-tokens"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn hint_round_trips_server_and_client_filters() {
        let filter = WhereFilter::parse(Some(
            "{ block: { number: { _lte: 2000 } }, log: { srcAddress: '0xabc', data: '0xdead' }, transaction: { value: { _gt: 1000 } } }",
        ))
        .unwrap();
        let hint = render_where_hint(&filter, 1500);
        assert_eq!(
            hint,
            "{ block: { number: { _gte: 1500, _lte: 2000 } }, transaction: { value: { _gt: 1000 } }, log: { srcAddress: \"0xabc\", data: \"0xdead\" } }",
        );
    }

    #[test]
    fn hint_folds_block_number_set_into_range() {
        let filter =
            WhereFilter::parse(Some("{ block: { number: { _in: [100, 50, 200] } } }")).unwrap();
        let hint = render_where_hint(&filter, 120);
        assert_eq!(
            hint,
            "{ block: { number: { _gte: 120, _lte: 200, _in: [100,50,200] } } }",
        );
    }

    #[test]
    fn hint_includes_block_and_status_filters() {
        let filter = WhereFilter::parse(Some(
            "{ block: { miner: '0xbeef' }, transaction: { status: 1, type: [0, 2] } }",
        ))
        .unwrap();
        let hint = render_where_hint(&filter, 100);
        assert_eq!(
            hint,
            "{ block: { number: { _gte: 100 }, miner: \"0xbeef\" }, transaction: { status: 1, type: [0,2] } }",
        );
    }
}
