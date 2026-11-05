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

// Caps on how much one answer may hold, as providers word them. Matched by
// message rather than by code: -32005 also means throttling on geth-based
// endpoints, and a request split into more requests is the wrong answer to
// that. Range-width limits are left out too, since asking by address doesn't
// narrow the range.
static RESULT_CAP: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"(?i)more than \d+ (logs|results)|\d+ logs returned|too many (logs|results)|exceeds max results|response size|result size|response too large|logs matched by query exceeds limit",
    )
    .unwrap()
});
static RATE_LIMITED: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)rate.?limit|too many requests|request rate|compute units|throughput").unwrap()
});

/// Whether a provider refused an `eth_getLogs` for what the answer would hold,
/// as opposed to throttling the caller or limiting the range.
pub fn is_result_cap_message(message: &str) -> bool {
    RESULT_CAP.is_match(message) && !RATE_LIMITED.is_match(message)
}

// Refusals of the request itself rather than of the block it names, as
// providers word them: publicnode's Polygon endpoint answers every
// `eth_getLogs` by `blockHash` with "Archive requests require a personal token".
static UNSUPPORTED_REQUEST: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)archive|not supported|unsupported|not available|not allowed|method not found")
        .unwrap()
});

/// Whether a provider refused a request as one it doesn't serve, invalid
/// params and missing methods included, so asking again the same way is
/// futile. Anything else, a block it doesn't know included, may answer on a
/// later attempt.
pub fn is_unsupported_request(code: i64, message: &str) -> bool {
    code == -32601 || code == -32602 || UNSUPPORTED_REQUEST.is_match(message)
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

    /// Every provider message the classifier is meant to recognise, with the
    /// block interval it should read out of it and whether that is a structural
    /// cap on the whole source (`true`) or a one-off suggestion for this query.
    /// Ordering matters in the classifier — a message can match both a
    /// "maximum allowed" pattern and a bare "block range too large" — so the
    /// pairs that overlap are kept adjacent here.
    #[test]
    fn known_provider_messages_yield_their_block_interval() {
        let cases = [
            (
                "query exceeds max results 20000, retry with the range 6000000-6000509",
                Some((510, false)),
            ),
            (
                "block range too large (2000), maximum allowed is 1000 blocks",
                Some((1000, true)),
            ),
            ("block range too large", Some((2000, true))),
            (
                "eth_getLogs is limited to a 1000 blocks range",
                Some((1000, true)),
            ),
            (
                "You can make eth_getLogs requests with up to a 500 block range. Based on your \
                 parameters, this block range should work: [0x3d7773, 0x3d7966]",
                Some((500, true)),
            ),
            ("Max range: 3500", Some((3500, true))),
            (
                "Maximum allowed number of requested blocks is 3500",
                Some((3500, true)),
            ),
            ("limited to 2000 block", Some((2000, true))),
            (
                "exceeds the range allowed for your plan (5000 > 3000)",
                Some((3000, true)),
            ),
            ("Block range limit exceeded.", Some((10000, true))),
            (
                "please limit the query to at most 1000 blocks",
                Some((1000, true)),
            ),
            ("maximum block range: 2000", Some((2000, true))),
            ("query exceeds max block range 1000", Some((1000, true))),
            // Not a range limit at all.
            (
                "height is not available (requested height: 138913957, base height: 155251499)",
                None,
            ),
            // A range that ends before it starts describes no interval.
            (
                "query exceeds max results 20000, retry with the range 6000509-6000000",
                None,
            ),
        ];
        assert_eq!(
            cases.map(|(message, _)| suggested_block_interval_from_message(message)),
            cases.map(|(_, expected)| expected),
        );
    }

    #[test]
    fn too_large_classifies_known_providers_and_ignores_unrelated() {
        let messages = [
            "More than 50000 logs returned",
            "query returned more than 10000 results",
            "query exceeds max results",
            "backend response too large",
            "logs matched by query exceeds limit of 10000",
            // Block-range limits belong to suggested_block_interval_from_message.
            "eth_getLogs is limited to a 1000 blocks range",
            "rate limited",
        ];
        assert_eq!(
            messages.map(is_response_too_large_message),
            [true, true, true, true, true, false, false]
        );
    }

    #[test]
    fn result_caps_exclude_throttling_and_range_limits() {
        let messages = [
            "query returned more than 10000 results",
            "Log response size exceeded. You can make eth_getLogs requests with up to a 2K \
             block range and no limit on the response size",
            "too many results",
            "More than 50000 logs returned",
            // Geth-based endpoints' throttling, under the same -32005 code.
            "limit exceeded",
            "project ID request rate exceeded",
            "Your app has exceeded its compute units per second capacity",
            "Too Many Requests",
            "block range is too wide",
            "header not found",
        ];
        assert_eq!(
            messages.map(is_result_cap_message),
            [true, true, true, true, false, false, false, false, false, false]
        );
    }

    #[test]
    fn unsupported_requests_are_told_from_a_block_the_node_does_not_know() {
        let refusals = [
            (-32602, "Archive requests require a personal token. Get one at: https://www.allnodes.com/publicnode"),
            (-32601, "the method eth_getLogs does not exist/is not available"),
            (-32000, "blockHash filter not supported"),
            // A node that hasn't got the block, as geth, op-geth and erigon word it.
            (-32000, "unknown block"),
            (-32001, "block not found: hash 0x11"),
            (-32000, "header not found"),
            (-32005, "rate limit exceeded"),
        ];
        assert_eq!(
            refusals.map(|(code, message)| is_unsupported_request(code, message)),
            [true, true, true, false, false, false, false]
        );
    }
}
