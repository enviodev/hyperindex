use hypersync_solana_net_types::types::Address;
use napi_derive::napi;

/// Whether a handler-supplied string is a base58 SVM pubkey. Called while
/// resolving an `onInstruction` `where`, so a typo is reported against the
/// registration rather than matching nothing: account filters are compared as
/// raw base58 text when instructions are routed.
#[napi]
pub fn is_svm_pubkey(value: String) -> bool {
    value.parse::<Address>().is_ok()
}

#[cfg(test)]
mod tests {
    #[test]
    fn accepts_a_pubkey_and_rejects_near_misses() {
        let checks = [
            "So11111111111111111111111111111111111111112",
            "not a pubkey",
            "",
            // Valid base58 alphabet, but not 32 bytes.
            "So1111111111111111111111111111111111111111211111",
        ]
        .map(|value| super::is_svm_pubkey(value.to_string()));
        assert_eq!(checks, [true, false, false, false]);
    }
}
