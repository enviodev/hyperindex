//! The address store's registrations as columns, and the index from an address
//! key to them. Sized for tens of millions of addresses: a registration is its
//! key bytes plus seven bytes of columns, and the index a `u32` slot or two.

use std::collections::HashMap;

/// A registration's position in the columns, fixed for the life of the store.
pub(crate) type Id = u32;

pub(crate) struct Entries {
    /// `None` for keys of varying width (SVM base58 text).
    key_width: Option<usize>,
    key_bytes: Vec<u8>,
    /// Where each key ends in `key_bytes`, for keys of varying width only.
    key_ends: Vec<u64>,
    contract_idx: Vec<u16>,
    /// -1 for a config address.
    registration_block: Vec<i32>,
    /// Rolled back past its registration block. The row stays so live ids
    /// never shift.
    dead: Vec<u64>,
}

impl Entries {
    pub(crate) fn new(key_width: Option<usize>) -> Self {
        Entries {
            key_width,
            key_bytes: Vec::new(),
            key_ends: Vec::new(),
            contract_idx: Vec::new(),
            registration_block: Vec::new(),
            dead: Vec::new(),
        }
    }

    pub(crate) fn len(&self) -> usize {
        self.contract_idx.len()
    }

    pub(crate) fn push(&mut self, key: &[u8], contract_idx: u16, registration_block: i32) -> Id {
        let id = Id::try_from(self.len()).expect("the address store holds at most u32::MAX rows");
        debug_assert!(self.key_width.is_none_or(|width| width == key.len()));
        self.key_bytes.extend_from_slice(key);
        if self.key_width.is_none() {
            self.key_ends.push(self.key_bytes.len() as u64);
        }
        self.contract_idx.push(contract_idx);
        self.registration_block.push(registration_block);
        if id as usize / 64 == self.dead.len() {
            self.dead.push(0);
        }
        id
    }

    pub(crate) fn key(&self, id: Id) -> &[u8] {
        let row = id as usize;
        match self.key_width {
            Some(width) => &self.key_bytes[row * width..(row + 1) * width],
            None => {
                let start = if row == 0 {
                    0
                } else {
                    self.key_ends[row - 1] as usize
                };
                &self.key_bytes[start..self.key_ends[row] as usize]
            }
        }
    }

    pub(crate) fn contract_idx(&self, id: Id) -> u32 {
        u32::from(self.contract_idx[id as usize])
    }

    pub(crate) fn registration_block(&self, id: Id) -> i64 {
        i64::from(self.registration_block[id as usize])
    }

    pub(crate) fn is_dead(&self, id: Id) -> bool {
        self.dead[id as usize / 64] & (1 << (id % 64)) != 0
    }

    pub(crate) fn kill(&mut self, id: Id) {
        self.dead[id as usize / 64] |= 1 << (id % 64);
    }

    pub(crate) fn heap_bytes(&self) -> usize {
        self.key_bytes.capacity()
            + self.key_ends.capacity() * 8
            + self.contract_idx.capacity() * 2
            + self.registration_block.capacity() * 4
            + self.dead.capacity() * 8
    }
}

/// From an address key to the live registrations of it: an open-addressing
/// table holding the head registration of each key, and beside it the rest
/// for the few keys several contracts own.
#[derive(Default)]
pub(crate) struct KeyIndex {
    /// `id + 1` of each key's head registration; 0 is an empty slot.
    slots: Vec<u32>,
    /// The top bits of each slot's key hash, never 0 for a taken slot: a
    /// probe walks these alone and reads a slot and its key only on a match.
    tags: Vec<u8>,
    keys: usize,
    /// The next registration of the same key under another contract.
    next: HashMap<Id, Id>,
}

const HASH_MULTIPLIER: u64 = 0x9E37_79B9_7F4A_7C15;

fn hash_key(key: &[u8]) -> u64 {
    let mix = |hash: u64, word: u64| {
        let hash = (hash ^ word).wrapping_mul(HASH_MULTIPLIER);
        hash ^ (hash >> 29)
    };
    let mut hash = key.len() as u64;
    let mut words = key.chunks_exact(8);
    for word in &mut words {
        hash = mix(
            hash,
            u64::from_le_bytes(word.try_into().expect("8-byte chunk")),
        );
    }
    let rest = words.remainder();
    if !rest.is_empty() {
        let mut word = [0u8; 8];
        word[..rest.len()].copy_from_slice(rest);
        hash = mix(hash, u64::from_le_bytes(word));
    }
    hash.wrapping_mul(HASH_MULTIPLIER) ^ (hash >> 32)
}

fn tag_of(hash: u64) -> u8 {
    (hash >> 56) as u8 | 1
}

impl KeyIndex {
    fn mask(&self) -> usize {
        self.slots.len() - 1
    }

    fn home(&self, key: &[u8]) -> usize {
        hash_key(key) as usize & self.mask()
    }

    /// The slot holding `key`, or the empty slot it would take.
    fn find(&self, key: &[u8], entries: &Entries) -> Result<usize, usize> {
        let hash = hash_key(key);
        let tag = tag_of(hash);
        let mut slot = hash as usize & self.mask();
        loop {
            match self.tags[slot] {
                0 => return Err(slot),
                found if found == tag && entries.key(self.slots[slot] - 1) == key => {
                    return Ok(slot);
                }
                _ => slot = (slot + 1) & self.mask(),
            }
        }
    }

    /// The live registration of `key` added last.
    pub(crate) fn head(&self, key: &[u8], entries: &Entries) -> Option<Id> {
        if self.slots.is_empty() {
            return None;
        }
        self.find(key, entries)
            .ok()
            .map(|slot| self.slots[slot] - 1)
    }

    pub(crate) fn next(&self, id: Id) -> Option<Id> {
        self.next.get(&id).copied()
    }

    /// Makes `id` the head of its key's registrations.
    pub(crate) fn insert(&mut self, id: Id, entries: &Entries) {
        if (self.keys + 1) * 4 > self.slots.len() * 3 {
            self.grow(entries);
        }
        match self.find(entries.key(id), entries) {
            Ok(slot) => {
                self.next.insert(id, self.slots[slot] - 1);
                self.slots[slot] = id + 1;
            }
            Err(slot) => {
                self.slots[slot] = id + 1;
                self.tags[slot] = tag_of(hash_key(entries.key(id)));
                self.keys += 1;
            }
        }
    }

    fn grow(&mut self, entries: &Entries) {
        let capacity = (self.slots.len() * 2).max(16);
        let old_slots = std::mem::replace(&mut self.slots, vec![0; capacity]);
        let old_tags = std::mem::replace(&mut self.tags, vec![0; capacity]);
        for (value, tag) in old_slots
            .into_iter()
            .zip(old_tags)
            .filter(|(_, tag)| *tag != 0)
        {
            let mut slot = self.home(entries.key(value - 1));
            while self.tags[slot] != 0 {
                slot = (slot + 1) & self.mask();
            }
            self.slots[slot] = value;
            self.tags[slot] = tag;
        }
    }

    /// Takes `id` out of its key's registrations, leaving the key's other
    /// owners in place.
    pub(crate) fn remove(&mut self, id: Id, entries: &Entries) {
        let Ok(slot) = self.find(entries.key(id), entries) else {
            return;
        };
        let head = self.slots[slot] - 1;
        if head == id {
            match self.next.remove(&id) {
                Some(next) => self.slots[slot] = next + 1,
                None => self.clear_slot(slot, entries),
            }
            return;
        }
        let mut cursor = head;
        while let Some(next) = self.next(cursor) {
            if next == id {
                match self.next.remove(&id) {
                    Some(after) => self.next.insert(cursor, after),
                    None => self.next.remove(&cursor),
                };
                return;
            }
            cursor = next;
        }
    }

    /// Empties a slot, shifting back the entries a probe would no longer reach.
    fn clear_slot(&mut self, slot: usize, entries: &Entries) {
        let mut hole = slot;
        let mut probe = slot;
        loop {
            probe = (probe + 1) & self.mask();
            if self.tags[probe] == 0 {
                break;
            }
            let value = self.slots[probe];
            let home = self.home(entries.key(value - 1));
            let reachable_from_hole = if hole <= probe {
                home <= hole || home > probe
            } else {
                home <= hole && home > probe
            };
            if reachable_from_hole {
                self.slots[hole] = value;
                self.tags[hole] = self.tags[probe];
                hole = probe;
            }
        }
        self.slots[hole] = 0;
        self.tags[hole] = 0;
        self.keys -= 1;
    }

    pub(crate) fn heap_bytes(&self) -> usize {
        self.slots.capacity() * 5 + self.next.capacity() * 16
    }
}
