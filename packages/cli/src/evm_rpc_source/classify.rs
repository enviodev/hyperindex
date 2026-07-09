//! Provider error-message classification for the RPC paging retry decision.
use regex::Regex;
use std::sync::LazyLock;

// Deterministic "the range returned too much data" errors that carry no
// numeric block-range suggestion (HyperRPC's 50k-log cap, response-size and
// result-count limits). They depend on log density, not on a fixed block
// window, so waiting never helps — the same range always re-trips the same
// cap. The reaction is to shrink the range and retry immediately, ratcheting
// the max range down.
static TOO_LARGE_PATTERNS: LazyLock<Vec<Regex>> = LazyLock::new(|| {
    vec![
        Regex::new(r"(?i)more than \d+ logs").unwrap(),
        Regex::new(r"(?i)\d+ logs returned").unwrap(),
        Regex::new(r"(?i)too many logs").unwrap(),
        Regex::new(r"(?i)query returned more than \d+ results").unwrap(),
        Regex::new(r"(?i)query exceeds max results").unwrap(),
        Regex::new(r"(?i)response size should not").unwrap(),
        Regex::new(r"(?i)(backend )?response too large").unwrap(),
        Regex::new(r"(?i)logs matched by query exceeds limit").unwrap(),
        Regex::new(r"(?i)block range is too wide").unwrap(),
    ]
});

pub fn is_response_too_large_message(message: &str) -> bool {
    TOO_LARGE_PATTERNS.iter().any(|re| re.is_match(message))
}

// Unknown provider: "retry with the range 123-456"
static SUGGESTED_RANGE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"retry with the range (\d+)-(\d+)").unwrap());
// QuickNode, 1RPC, Blast: "limited to a 1000 blocks range"
static BLOCK_RANGE_LIMIT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"limited to a (\d+) blocks range").unwrap());
// Alchemy: "up to a 500 block range"
static ALCHEMY_RANGE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"up to a (\d+) block range").unwrap());
// Cloudflare: "Max range: 3500"
static CLOUDFLARE_RANGE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"Max range: (\d+)").unwrap());
// Thirdweb: "Maximum allowed number of requested blocks is 3500"
static THIRDWEB_RANGE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"Maximum allowed number of requested blocks is (\d+)").unwrap());
// BlockPI: "limited to 2000 block"
static BLOCKPI_RANGE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"limited to (\d+) block").unwrap());
// Base: "block range too large" - fixed 2000 block limit
static BASE_RANGE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"block range too large").unwrap());
// evm-rpc.sei-apis.com: "block range too large (2000), maximum allowed is 1000 blocks"
static MAX_ALLOWED_BLOCKS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"maximum allowed is (\d+) blocks").unwrap());
// Blast (paid): "exceeds the range allowed for your plan (5000 > 3000)"
static BLAST_PAID: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"exceeds the range allowed for your plan \(\d+ > (\d+)\)").unwrap()
});
// Chainstack: "Block range limit exceeded" - 10000 block limit
static CHAINSTACK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"Block range limit exceeded\.").unwrap());
// Coinbase: "please limit the query to at most 1000 blocks"
static COINBASE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"please limit the query to at most (\d+) blocks").unwrap());
// PublicNode: "maximum block range: 2000"
static PUBLIC_NODE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"maximum block range: (\d+)").unwrap());
// Hyperliquid: "query exceeds max block range 1000"
static HYPERLIQUID: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"query exceeds max block range (\d+)").unwrap());

fn extract_positive_u64(re: &Regex, message: &str) -> Option<u64> {
    let n: u64 = re.captures(message)?.get(1)?.as_str().parse().ok()?;
    (n > 0).then_some(n)
}

/// Returns `Some((suggested block interval, is the provider's structural max))`.
pub fn suggested_block_interval_from_message(message: &str) -> Option<(u64, bool)> {
    if let Some(caps) = SUGGESTED_RANGE.captures(message) {
        let from: u64 = caps.get(1)?.as_str().parse().ok()?;
        let to: u64 = caps.get(2)?.as_str().parse().ok()?;
        return (to >= from).then(|| (to - from + 1, false));
    }
    if let Some(n) = extract_positive_u64(&BLOCK_RANGE_LIMIT, message) {
        return Some((n, true));
    }
    if let Some(n) = extract_positive_u64(&ALCHEMY_RANGE, message) {
        return Some((n, true));
    }
    if let Some(n) = extract_positive_u64(&CLOUDFLARE_RANGE, message) {
        return Some((n, true));
    }
    if let Some(n) = extract_positive_u64(&THIRDWEB_RANGE, message) {
        return Some((n, true));
    }
    if let Some(n) = extract_positive_u64(&BLOCKPI_RANGE, message) {
        return Some((n, true));
    }
    if let Some(n) = extract_positive_u64(&MAX_ALLOWED_BLOCKS, message) {
        return Some((n, true));
    }
    if BASE_RANGE.is_match(message) {
        return Some((2000, true));
    }
    if let Some(n) = extract_positive_u64(&BLAST_PAID, message) {
        return Some((n, true));
    }
    if CHAINSTACK.is_match(message) {
        return Some((10000, true));
    }
    if let Some(n) = extract_positive_u64(&COINBASE, message) {
        return Some((n, true));
    }
    if let Some(n) = extract_positive_u64(&PUBLIC_NODE, message) {
        return Some((n, true));
    }
    if let Some(n) = extract_positive_u64(&HYPERLIQUID, message) {
        return Some((n, true));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retry_with_range() {
        let message = "query exceeds max results 20000, retry with the range 6000000-6000509";
        assert_eq!(
            suggested_block_interval_from_message(message),
            Some((510, false))
        );
    }

    #[test]
    fn ignores_unrelated_errors() {
        let message =
            "height is not available (requested height: 138913957, base height: 155251499)";
        assert_eq!(suggested_block_interval_from_message(message), None);
    }

    #[test]
    fn block_range_too_large_with_max_allowed() {
        let message = "block range too large (2000), maximum allowed is 1000 blocks";
        assert_eq!(
            suggested_block_interval_from_message(message),
            Some((1000, true))
        );
    }

    #[test]
    fn ignores_inverted_range() {
        let message = "query exceeds max results 20000, retry with the range 6000509-6000000";
        assert_eq!(suggested_block_interval_from_message(message), None);
    }

    #[test]
    fn one_rpc_block_range_limit() {
        let message = "eth_getLogs is limited to a 1000 blocks range";
        assert_eq!(
            suggested_block_interval_from_message(message),
            Some((1000, true))
        );
    }

    #[test]
    fn alchemy_block_range() {
        let message = "You can make eth_getLogs requests with up to a 500 block range. Based on your parameters, this block range should work: [0x3d7773, 0x3d7966]";
        assert_eq!(
            suggested_block_interval_from_message(message),
            Some((500, true))
        );
    }

    #[test]
    fn base_fixed_range() {
        assert_eq!(
            suggested_block_interval_from_message("block range too large"),
            Some((2000, true))
        );
    }

    #[test]
    fn chainstack_fixed_range() {
        assert_eq!(
            suggested_block_interval_from_message("Block range limit exceeded."),
            Some((10000, true))
        );
    }

    #[test]
    fn too_large_classifies_known_providers_and_ignores_unrelated() {
        assert!(is_response_too_large_message(
            "More than 50000 logs returned"
        ));
        assert!(is_response_too_large_message(
            "query returned more than 10000 results"
        ));
        assert!(is_response_too_large_message("query exceeds max results"));
        assert!(is_response_too_large_message("backend response too large"));
        assert!(is_response_too_large_message(
            "logs matched by query exceeds limit of 10000"
        ));
        // Block-range limits are handled by suggested_block_interval_from_message, not here.
        assert!(!is_response_too_large_message(
            "eth_getLogs is limited to a 1000 blocks range"
        ));
        assert!(!is_response_too_large_message("rate limited"));
    }
}
