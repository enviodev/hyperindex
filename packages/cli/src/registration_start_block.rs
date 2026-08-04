//! The earliest block a registration accepts an item at: its contract's
//! configured start block, overridden by a `where.block.*._gte` on the
//! registration itself.
//!
//! This can't be folded into the address store's gate. That one is
//! contract-wide, so a sibling registration without a start block holds it open
//! from the chain start for every registration of the contract alike — only a
//! per-registration check keeps the restricted one out. Every ecosystem's
//! router applies the same rule, so it lives here rather than three times over.

/// Whether a registration whose start block is `start_block` (`None` being
/// unrestricted) accepts an item at `block_number`.
pub fn has_started(start_block: Option<i64>, block_number: i64) -> bool {
    match start_block {
        Some(start_block) => block_number >= start_block,
        None => true,
    }
}

#[cfg(test)]
mod tests {
    use super::has_started;

    #[test]
    fn unrestricted_accepts_every_block_and_a_start_block_is_inclusive() {
        assert_eq!(
            (
                has_started(None, 0),
                has_started(Some(100), 99),
                has_started(Some(100), 100),
                has_started(Some(100), 101),
            ),
            (true, false, true, true)
        );
    }
}
