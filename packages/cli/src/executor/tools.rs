use crate::clap_definitions::{FetchDocsArgs, SearchDocsArgs, ToolsSubcommand};
use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use std::time::Duration;

const MCP_ENDPOINT: &str = "https://docs.envio.dev/mcp";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

pub async fn run(subcommand: ToolsSubcommand) -> Result<()> {
    let text = run_to_string(subcommand).await?;
    println!("{text}");
    Ok(())
}

const SEARCH_LIMIT: u8 = 10;

async fn run_to_string(subcommand: ToolsSubcommand) -> Result<String> {
    match subcommand {
        ToolsSubcommand::SearchDocs(args) => {
            let text = call_mcp_tool(
                "docs_search",
                json!({ "query": args.query, "limit": SEARCH_LIMIT }),
            )
            .await?;
            Ok(text.replace(
                "Use docs_fetch with the URL to retrieve the full page content.",
                "Use `envio tools fetch-docs <url>` to retrieve the full page content.",
            ))
        }
        ToolsSubcommand::FetchDocs(args) => {
            call_mcp_tool("docs_fetch", json!({ "url": args.url })).await
        }
    }
}

/// Calls a tool on the Envio docs MCP server over Streamable HTTP and
/// returns the concatenated text content from the response.
async fn call_mcp_tool(name: &str, arguments: Value) -> Result<String> {
    let client = reqwest::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .context("Failed building HTTP client")?;

    let request_body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": { "name": name, "arguments": arguments },
    });

    let response = client
        .post(MCP_ENDPOINT)
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .json(&request_body)
        .send()
        .await
        .with_context(|| format!("Failed calling MCP endpoint {MCP_ENDPOINT}"))?;

    let status = response.status();
    let raw = response
        .text()
        .await
        .with_context(|| format!("Failed reading response body from {MCP_ENDPOINT}"))?;

    if !status.is_success() {
        return Err(anyhow!(
            "MCP endpoint {MCP_ENDPOINT} returned {status}: {raw}"
        ));
    }

    let payload: Value =
        parse_mcp_payload(&raw).with_context(|| format!("Failed parsing MCP response: {raw}"))?;

    if let Some(err) = payload.get("error") {
        return Err(anyhow!("MCP tool {name} returned error: {err}"));
    }

    let content = payload
        .get("result")
        .and_then(|r| r.get("content"))
        .and_then(|c| c.as_array())
        .ok_or_else(|| anyhow!("MCP response missing result.content array: {payload}"))?;

    let mut out = String::new();
    for block in content {
        if block.get("type").and_then(Value::as_str) == Some("text") {
            if let Some(text) = block.get("text").and_then(Value::as_str) {
                if !out.is_empty() {
                    out.push('\n');
                }
                out.push_str(text);
            }
        }
    }
    Ok(out)
}

/// The MCP server may answer either with a JSON body or with an SSE stream
/// (`text/event-stream`) depending on negotiation. Handle both: for SSE,
/// concatenate the `data:` lines and parse the result.
fn parse_mcp_payload(raw: &str) -> Result<Value> {
    let trimmed = raw.trim_start();
    if trimmed.starts_with('{') || trimmed.starts_with('[') {
        return serde_json::from_str(trimmed).context("Invalid JSON body");
    }
    let mut data = String::new();
    for line in raw.lines() {
        if let Some(rest) = line.strip_prefix("data:") {
            data.push_str(rest.trim_start());
        }
    }
    if data.is_empty() {
        return Err(anyhow!("Empty MCP response body"));
    }
    serde_json::from_str(&data).context("Invalid JSON in SSE data frame")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clap_definitions::SearchDocsArgs;
    use serde_json::json;

    #[tokio::test]
    async fn search_docs_clickhouse_support() {
        let subcommand = ToolsSubcommand::SearchDocs(SearchDocsArgs {
            query: "clickhouse support".to_string(),
        });
        let text = run_to_string(subcommand).await.expect("live MCP call");
        insta::assert_snapshot!(text);
    }

    #[test]
    fn parses_json_and_sse_envelopes_identically() {
        let json_body = r#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#;
        let sse_body =
            "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n\n";
        let expected = json!({"jsonrpc":"2.0","id":1,"result":{"ok":true}});

        assert_eq!(
            (
                parse_mcp_payload(json_body).expect("json"),
                parse_mcp_payload(sse_body).expect("sse"),
                parse_mcp_payload("").is_err(),
            ),
            (expected.clone(), expected, true),
        );
    }
}
