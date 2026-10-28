//! The bit layout of `BloomFilter.res`'s layers, so storage can build one from
//! the values it holds and hand JavaScript the bits rather than the values.
//!
//! The hash runs over UTF-16 code units, as `String.charCodeAt` reads them, so a
//! key hashes the same on both sides.

pub const HASH_COUNT: u32 = 7;
pub const BITS_PER_KEY: u64 = 10;

/// cyrb53's two 32-bit lanes; the second made odd, so its probes step through
/// every position of a power-of-two layer.
fn hash(key: &str) -> (u32, u32) {
    let mut h1: u32 = 0xdeadbeef;
    let mut h2: u32 = 0x41c6ce57;
    for unit in key.encode_utf16() {
        let unit = u32::from(unit);
        h1 = (h1 ^ unit).wrapping_mul(2654435761);
        h2 = (h2 ^ unit).wrapping_mul(1597334677);
    }
    h1 = (h1 ^ (h1 >> 16)).wrapping_mul(2246822507);
    h1 ^= (h2 ^ (h2 >> 13)).wrapping_mul(3266489909);
    h2 = (h2 ^ (h2 >> 16)).wrapping_mul(2246822507);
    h2 ^= (h1 ^ (h1 >> 13)).wrapping_mul(3266489909);
    (h1, h2 | 1)
}

/// A layer sized for `capacity` keys: a power-of-two bit count of at least 32.
pub fn bit_count_for(capacity: u64) -> u64 {
    (capacity * BITS_PER_KEY).max(32).next_power_of_two()
}

pub struct Layer {
    pub words: Vec<u32>,
    mask: u32,
}

impl Layer {
    pub fn new(bit_count: u64) -> Self {
        Self {
            words: vec![0; (bit_count / 32) as usize],
            mask: (bit_count - 1) as u32,
        }
    }

    pub fn add(&mut self, key: &str) {
        let (h1, h2) = hash(key);
        for i in 0..HASH_COUNT {
            let bit = h1.wrapping_add(i.wrapping_mul(h2)) & self.mask;
            self.words[(bit >> 5) as usize] |= 1 << (bit & 31);
        }
    }

    #[cfg(test)]
    fn has(&self, key: &str) -> bool {
        let (h1, h2) = hash(key);
        (0..HASH_COUNT).all(|i| {
            let bit = h1.wrapping_add(i.wrapping_mul(h2)) & self.mask;
            self.words[(bit >> 5) as usize] & (1 << (bit & 31)) != 0
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The bits `BloomFilter.res` sets for these keys in a 32-bit layer, read
    // off `BloomFilter.make(~initialCapacity=1)` after adding each.
    #[test]
    fn sets_the_bits_javascript_sets() {
        let words = |key: &str| {
            let mut layer = Layer::new(32);
            layer.add(key);
            layer.words[0]
        };
        assert_eq!(
            [words(""), words("0xabc"), words("é∑")],
            [JS_EMPTY, JS_HEX, JS_UNICODE]
        );
    }

    #[test]
    fn reports_every_added_key() {
        let mut layer = Layer::new(bit_count_for(1000));
        let keys: Vec<String> = (0..1000).map(|i| format!("0x{i:040x}")).collect();
        keys.iter().for_each(|key| layer.add(key));
        assert!(keys.iter().all(|key| layer.has(key)));
    }

    const JS_EMPTY: u32 = 304103561;
    const JS_HEX: u32 = 1426074112;
    const JS_UNICODE: u32 = 101199937;
}
