// build.rs

use std::{env, fs, path::Path};

fn main() {
    println!("cargo:rerun-if-changed=build.rs");

    // ---- 1. Fetch API ----
    let body = reqwest::blocking::get("https://chains.hyperquery.xyz/active_chains")
        .expect("Failed to fetch networks API")
        .text()
        .expect("Failed to read response body");

    let json: serde_json::Value =
        serde_json::from_str(&body).expect("Invalid JSON from network API");

    let arr = json.as_array().expect("Root must be array");

    // ---- Extract network names ----
    let names: Vec<String> = arr
        .iter()
        .filter_map(|v| v.get("name").and_then(|n| n.as_str()))
        .map(|s| s.to_string())
        .collect();

    // ---- Extract mapping: name => chain_id ----
    let map_entries: Vec<String> = arr
        .iter()
        .filter_map(|v| {
            let name = v.get("name")?.as_str()?;
            let id = v.get("chain_id")?.as_u64()?;
            Some(format!("(\"{}\", {})", name, id))
        })
        .collect();

    // ---- 2. Generate Rust file ----
    let generated = format!(
        "
        pub const NETWORK_NAMES: &[&str] = &[{}];

        pub const NETWORK_MAP: &[(&str, u64)] = &[
            {}
        ];
        ",
        names
            .iter()
            .map(|s| format!("\"{}\"", s))
            .collect::<Vec<_>>()
            .join(", "),
        map_entries.join(",\n")
    );

    // ---- 3. Write to OUT_DIR ----
    let out = env::var("OUT_DIR").unwrap();
    let dest = Path::new(&out).join("network_generated.rs");
    fs::write(dest, generated).expect("Failed to write network_generated.rs");
}
