use std::path::Path;
use std::time::Duration;

use crate::cli_args::clap_definitions::SubgraphDiffArgs;
use crate::subgraph::diff::{self, Options};

/// Runs the diff and prints its report; the exit code is the verdict.
pub async fn run(args: SubgraphDiffArgs, project_root: &Path) -> i32 {
    let options = Options {
        endpoint: args.endpoint,
        ours: args.ours,
        block: args.block,
        sample: args.sample,
        types: args.types,
        tolerance_pct: args.tolerance,
        max_field_mismatches: args.max_field_mismatches,
        concurrency: args.concurrency,
        max_entities: (args.max_entities > 0).then_some(args.max_entities),
        headers: args.headers,
        allow_indexing_errors: args.allow_indexing_errors,
        timeout: Duration::from_secs(args.timeout.max(1)),
        progress: true,
    };
    let report = diff::run(project_root, &options).await;
    if args.json {
        match serde_json::to_string_pretty(&report) {
            Ok(json) => println!("{json}"),
            Err(err) => {
                eprintln!("Failed to serialize the report: {err}");
                return 2;
            }
        }
    } else {
        print!("{}", report.render_table());
    }
    report.exit_code
}
