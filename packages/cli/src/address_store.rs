//! Per-chain address index, kept in Rust. Every address the chain indexes —
//! config-declared or dynamically registered — lives here once, keyed by its
//! binary form so a checksummed and a lowercase spelling of the same EVM
//! address can't diverge. The store owns registration bookkeeping (conflict
//! detection, `effectiveStartBlock` derivation, reorg rollback) and hands out
//! `AddressSet` handles: immutable, ordered snapshots that a fetch-state
//! partition carries instead of a JS address array.
//!
//! A set is ordered by `(effectiveStartBlock, address bytes)` — independent of
//! the ids inside it, so the same addresses produce byte-identical sets
//! whatever order they were registered or restored in. Everything a query
//! derives from a set (padded topics, the routing owner index, per-contract
//! counts) is computed once on first use and shared by every query the
//! partition makes.

use std::collections::HashMap;
use std::sync::{Arc, OnceLock, RwLock, RwLockReadGuard};

use napi_derive::napi;

use crate::field_columns::Ecosystem;

/// Binary form of an address, the identity the store keys on.
///
/// EVM and Fuel addresses are hex-decoded (20 and 32 bytes), so a checksummed
/// spelling and a lowercase one are the same key. SVM pubkeys keep their base58
/// bytes: that encoding is already canonical and case-sensitive, so decoding
/// would buy nothing and would cost a decode per routed instruction — where the
/// raw `programId` string is what the source hands us.
type Key = Box<[u8]>;

fn decode_hex_address(s: &str, len: usize) -> Option<Key> {
    let hex = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X"))?;
    if hex.len() != len * 2 {
        return None;
    }
    let mut out = vec![0u8; len];
    faster_hex::hex_decode(hex.as_bytes(), &mut out).ok()?;
    Some(out.into_boxed_slice())
}

/// The binary key for an address string, or `None` when it isn't a well-formed
/// address for the ecosystem. Callers surface that as an `invalid` verdict
/// rather than throwing: a malformed dynamic registration should be skipped
/// with a warning, not take the indexer down.
fn address_key(ecosystem: Ecosystem, address: &str) -> Option<Key> {
    match ecosystem {
        Ecosystem::Evm { .. } => decode_hex_address(address, 20),
        Ecosystem::Fuel => decode_hex_address(address, 32),
        Ecosystem::Svm => {
            (!address.is_empty()).then(|| address.as_bytes().to_vec().into_boxed_slice())
        }
    }
}

/// Render a key back to the canonical string the JS side uses. EVM follows the
/// chain's `lowercaseAddresses` setting, the same way every address the sources
/// hand back is encoded.
fn address_string(ecosystem: Ecosystem, key: &[u8]) -> String {
    match ecosystem {
        Ecosystem::Evm { should_checksum } => {
            let mut bytes = [0u8; 20];
            bytes.copy_from_slice(key);
            if should_checksum {
                alloy_primitives::Address::from(bytes).to_checksum(None)
            } else {
                format!("0x{}", faster_hex::hex_string(&bytes))
            }
        }
        Ecosystem::Fuel => format!("0x{}", faster_hex::hex_string(key)),
        // The key is the base58 text itself.
        Ecosystem::Svm => String::from_utf8_lossy(key).into_owned(),
    }
}

/// Left-pad an EVM address to its 32-byte indexed-topic form, as lowercase hex.
fn address_topic(key: &[u8]) -> String {
    let mut topic = [0u8; 32];
    topic[32 - key.len()..].copy_from_slice(key);
    format!("0x{}", faster_hex::hex_string(&topic))
}

/// `max(max(registrationBlock, 0), contractStartBlock)` — a config address
/// (registration block -1) starts at its contract's start block, a dynamic one
/// no earlier than the block that registered it.
fn derive_effective_start_block(registration_block: i64, contract_start_block: i64) -> i64 {
    registration_block.max(0).max(contract_start_block)
}

struct Entry {
    key: Key,
    contract_idx: u32,
    registration_block: i64,
    effective_start_block: i64,
    /// Rolled back past its registration block. The slot stays so live ids
    /// never shift; the key is unmapped so the address can be registered afresh.
    dead: bool,
}

pub struct StoreInner {
    ecosystem: Ecosystem,
    contract_names: Vec<String>,
    contract_start_blocks: Vec<i64>,
    contract_depends_on_addresses: Vec<bool>,
    contract_idx_by_name: HashMap<String, u32>,
    entries: Vec<Entry>,
    id_by_key: HashMap<Key, u64>,
    live_count_by_contract: Vec<u32>,
    /// Ids of dynamic registrations not yet persisted to `envio_addresses`,
    /// in registration order. Drained by `drain_for_write` when the batch
    /// covering their registration block is written.
    unwritten: Vec<u64>,
}

impl StoreInner {
    fn entry(&self, id: u64) -> &Entry {
        &self.entries[id as usize]
    }

    fn contract_name(&self, idx: u32) -> &str {
        &self.contract_names[idx as usize]
    }

    /// Sort key giving a set its id-independent order. Addresses are globally
    /// unique across contracts, so `(effectiveStartBlock, bytes)` is total.
    fn sort_key(&self, id: u64) -> (i64, &[u8]) {
        let entry = self.entry(id);
        (entry.effective_start_block, &entry.key)
    }

    fn live_id(&self, key: &[u8]) -> Option<u64> {
        let id = *self.id_by_key.get(key)?;
        (!self.entry(id).dead).then_some(id)
    }

    /// The gate every address-dependent registration applies to a routed item:
    /// the address is registered for this contract and its effective start
    /// block is at or before the item's block.
    pub fn is_indexed_at(&self, key: &[u8], contract_idx: u32, block_number: i64) -> bool {
        match self.live_id(key) {
            Some(id) => {
                let entry = self.entry(id);
                entry.contract_idx == contract_idx && entry.effective_start_block <= block_number
            }
            None => false,
        }
    }

    pub fn contract_idx(&self, name: &str) -> Option<u32> {
        self.contract_idx_by_name.get(name).copied()
    }

    pub fn ecosystem(&self) -> Ecosystem {
        self.ecosystem
    }

    fn sorted_ids(&self, mut ids: Vec<u64>) -> Vec<u64> {
        ids.sort_unstable_by(|&a, &b| self.sort_key(a).cmp(&self.sort_key(b)));
        ids
    }

    /// Live ids from `min_id` up that `keep` accepts, in set order. Every
    /// selection the store makes runs through here, so "skips tombstones,
    /// comes out sorted" is one rule rather than four copies of a scan.
    fn sorted_live_ids(&self, min_id: u64, keep: impl Fn(&Entry) -> bool) -> Vec<u64> {
        let ids = (min_id..self.entries.len() as u64)
            .filter(|&id| {
                let entry = self.entry(id);
                !entry.dead && keep(entry)
            })
            .collect();
        self.sorted_ids(ids)
    }
}

/// A contract an address may be registered for: every contract the config
/// declares, on any chain, since `context.chain.<Contract>.add` validates
/// against that whole set. Fixed at construction.
#[napi(object)]
pub struct AddressStoreContract {
    pub name: String,
    /// The minimum `startBlock` across the contract's registrations on this
    /// chain; absent means block 0, since partitions never query below the
    /// chain's own start block anyway.
    pub start_block: Option<i64>,
    /// Whether any of this chain's events for the contract are fetched by
    /// address. False both for a config contract this chain has no events for
    /// and for one whose events are all wildcard — either way its addresses are
    /// registered and persisted, but no partition is ever built from them.
    pub depends_on_addresses: bool,
}

/// One address a batch asks the store to register.
#[napi(object)]
pub struct AddressRegistration {
    pub address: String,
    pub contract_name: String,
    /// -1 for a config address (not dynamically registered).
    pub registration_block: i64,
}

/// What the store did with one registration, in the batch's order. The caller
/// turns `duplicate`/`conflict`/`invalid` into the user-facing warning.
#[napi(object)]
pub struct RegistrationVerdict {
    /// `added` | `duplicate` | `conflict` | `invalid`
    pub kind: String,
    /// Whether an `added` address is one this chain fetches for — the store
    /// answers it because the store is what holds the contract list. False for
    /// every rejected verdict.
    pub fetchable: bool,
    /// Derived for the incoming registration; 0 when the address was rejected.
    pub effective_start_block: i64,
    /// The contract already holding this address — set for `duplicate` (same
    /// contract) and `conflict` (a different one).
    pub existing_contract_name: Option<String>,
    /// Set for `duplicate`, so the caller can warn when a later registration
    /// would have started earlier than the one already held.
    pub existing_effective_start_block: Option<i64>,
}

pub const VERDICT_ADDED: &str = "added";
pub const VERDICT_DUPLICATE: &str = "duplicate";
pub const VERDICT_CONFLICT: &str = "conflict";
pub const VERDICT_INVALID: &str = "invalid";

/// A distinct `effectiveStartBlock` present in a set (or in a store selection),
/// with how many addresses share it. Ascending — the fetch state walks these to
/// decide where one partition ends and the next begins.
#[napi(object)]
pub struct StartBlockGroup {
    pub start_block: i64,
    pub count: i64,
}

/// One address as JS sees it — the shape `Internal.indexingContract` expects.
#[napi(object)]
pub struct AddressEntry {
    pub address: String,
    pub contract_name: String,
    pub registration_block: i64,
    pub effective_start_block: i64,
}

/// A drained registration paired with the checkpoint that must own its row.
#[napi(object)]
pub struct DrainedAddress {
    pub address: String,
    pub contract_name: String,
    pub registration_block: i64,
    /// Index into the `checkpoint_block_numbers` passed to `drain_for_write`.
    /// The ids themselves are bigints the caller already holds, so only the
    /// pairing crosses the boundary.
    pub checkpoint_idx: u32,
}

/// Which of a contract's addresses `makeSet` should take.
#[napi(object)]
#[derive(Default)]
pub struct MakeSetOptions {
    /// Only addresses whose id is at or above this — ids are handed out in
    /// registration order, so a cursor read before a batch selects exactly what
    /// that batch added.
    pub min_id: Option<i64>,
    /// Inclusive `effectiveStartBlock` bounds.
    pub from_start_block: Option<i64>,
    pub to_start_block: Option<i64>,
    /// Applied last, over the ordered selection.
    pub offset: Option<i64>,
    pub limit: Option<i64>,
}

#[napi]
pub struct AddressStore {
    inner: Arc<RwLock<StoreInner>>,
}

#[napi]
impl AddressStore {
    /// `contracts` are every contract the config declares — registering an
    /// address for a name that isn't among them is a caller bug, not a
    /// user-facing rejection.
    #[napi(factory)]
    pub fn new_evm(should_checksum: bool, contracts: Vec<AddressStoreContract>) -> Self {
        Self::with_ecosystem(Ecosystem::Evm { should_checksum }, contracts)
    }

    #[napi(factory)]
    pub fn new_svm(contracts: Vec<AddressStoreContract>) -> Self {
        Self::with_ecosystem(Ecosystem::Svm, contracts)
    }

    #[napi(factory)]
    pub fn new_fuel(contracts: Vec<AddressStoreContract>) -> Self {
        Self::with_ecosystem(Ecosystem::Fuel, contracts)
    }

    /// The id the next added address will get. Captured before a batch, it
    /// becomes the `minId` that selects exactly that batch's additions.
    #[napi]
    pub fn next_id(&self) -> i64 {
        self.read().entries.len() as i64
    }

    /// Registers a batch of dynamic registrations, resolving each address
    /// against both the store and the batch's own earlier entries, so two
    /// contracts claiming one address inside a single batch conflict just as
    /// they would across batches. What it adds is marked pending persistence.
    #[napi]
    pub fn register_batch(
        &self,
        registrations: Vec<AddressRegistration>,
    ) -> napi::Result<Vec<RegistrationVerdict>> {
        self.register_all(registrations, true)
    }

    /// `register_batch` for addresses the database already holds — config
    /// addresses and the dynamic ones a resume restores. Nothing is marked
    /// pending, so nothing is ever written back.
    #[napi]
    pub fn seed_batch(
        &self,
        registrations: Vec<AddressRegistration>,
    ) -> napi::Result<Vec<RegistrationVerdict>> {
        self.register_all(registrations, false)
    }

    /// Drains the registrations awaiting persistence whose registration block is
    /// at or below `to_block_inclusive` — everything the batch being written
    /// covers — pairing each with the checkpoint at its registration block.
    /// What sits above that block stays pending for a later batch.
    ///
    /// A drained registration with no checkpoint at its block means it came from
    /// an event this batch never processed, which would write a row no rollback
    /// could reach. That errors with the queue untouched, so the caller can fail
    /// without the store having lied about what is still pending.
    #[napi]
    pub fn drain_for_write(
        &self,
        to_block_inclusive: i64,
        checkpoint_block_numbers: Vec<i64>,
    ) -> napi::Result<Vec<DrainedAddress>> {
        let mut store = self.inner.write().unwrap();
        let mut drained = Vec::new();
        let mut pending = Vec::new();
        for &id in store.unwritten.iter() {
            let entry = store.entry(id);
            if entry.registration_block > to_block_inclusive {
                pending.push(id);
                continue;
            }
            let Some(checkpoint_idx) = checkpoint_block_numbers
                .iter()
                .position(|&block| block == entry.registration_block)
            else {
                return Err(napi::Error::from_reason(format!(
                    "Registered address {} at block {} has no checkpoint in the batch that writes \
                     it.",
                    address_string(store.ecosystem, &entry.key),
                    entry.registration_block
                )));
            };
            drained.push(DrainedAddress {
                address: address_string(store.ecosystem, &entry.key),
                contract_name: store.contract_name(entry.contract_idx).to_string(),
                registration_block: entry.registration_block,
                checkpoint_idx: checkpoint_idx as u32,
            });
        }
        store.unwritten = pending;
        Ok(drained)
    }

    /// How many registrations await persistence. Lets the write path skip
    /// assembling a batch's checkpoints for the common chain that registered
    /// nothing.
    #[napi]
    pub fn pending_count(&self) -> i64 {
        self.read().unwritten.len() as i64
    }

    /// The registrations still awaiting persistence, in registration order. For
    /// assertions — draining is what the write path uses.
    #[napi]
    pub fn pending_entries(&self) -> Vec<AddressEntry> {
        let store = self.read();
        store
            .unwritten
            .iter()
            .map(|&id| {
                let entry = store.entry(id);
                AddressEntry {
                    address: address_string(store.ecosystem, &entry.key),
                    contract_name: store.contract_name(entry.contract_idx).to_string(),
                    registration_block: entry.registration_block,
                    effective_start_block: entry.effective_start_block,
                }
            })
            .collect()
    }

    /// An ordered snapshot of one contract's addresses. Empty selections are
    /// legal — a wildcard partition carries an empty set rather than none.
    #[napi]
    pub fn make_set(&self, contract_name: String, options: Option<MakeSetOptions>) -> AddressSet {
        let options = options.unwrap_or_default();
        let store = self.read();
        let ids = match store.contract_idx(&contract_name) {
            None => Vec::new(),
            Some(contract_idx) => {
                let min_id = options.min_id.unwrap_or(0).max(0) as u64;
                let ids = store.sorted_live_ids(min_id, |entry| {
                    entry.contract_idx == contract_idx
                        && options
                            .from_start_block
                            .is_none_or(|from| entry.effective_start_block >= from)
                        && options
                            .to_start_block
                            .is_none_or(|to| entry.effective_start_block <= to)
                });
                apply_window(&ids, options.offset, options.limit)
            }
        };
        drop(store);
        AddressSet::new(self.inner.clone(), ids)
    }

    /// A set over exactly these addresses, in set order. Addresses the store
    /// doesn't hold are skipped. Every set of a chain must come from that
    /// chain's one store — ids are store-scoped, so sets from different stores
    /// can't be merged.
    #[napi]
    pub fn make_set_of(&self, addresses: Vec<String>) -> AddressSet {
        let store = self.read();
        let ids: Vec<u64> = addresses
            .iter()
            .filter_map(|address| {
                let key = address_key(store.ecosystem, address)?;
                store.live_id(&key)
            })
            .collect();
        let ids = store.sorted_ids(ids);
        drop(store);
        AddressSet::new(self.inner.clone(), ids)
    }

    /// A set holding nothing — what an address-free (wildcard) partition
    /// carries, so every partition is queried through the same handle.
    #[napi]
    pub fn empty_set(&self) -> AddressSet {
        AddressSet::new(self.inner.clone(), Vec::new())
    }

    /// The distinct effective start blocks of a contract's addresses, ascending.
    #[napi]
    pub fn start_block_groups(&self, contract_name: String) -> Vec<StartBlockGroup> {
        let store = self.read();
        let Some(contract_idx) = store.contract_idx(&contract_name) else {
            return Vec::new();
        };
        let ids = store.sorted_live_ids(0, |entry| entry.contract_idx == contract_idx);
        group_start_blocks(&store, &ids)
    }

    #[napi]
    pub fn contract_count(&self, contract_name: String) -> i64 {
        let store = self.read();
        match store.contract_idx(&contract_name) {
            Some(idx) => i64::from(store.live_count_by_contract[idx as usize]),
            None => 0,
        }
    }

    /// Every live address across every contract — the count the chain reports
    /// as `numAddresses`.
    #[napi]
    pub fn size(&self) -> i64 {
        let store = self.read();
        let live: u32 = store.live_count_by_contract.iter().sum();
        i64::from(live)
    }

    /// Whether an address is registered for a contract and already started at
    /// `block_number` — the chain-wide gate, exposed for the simulate source,
    /// which has no real query boundary to gate at. Chain-wide, not partition
    /// membership: a caller that means "this partition holds it" wants
    /// `AddressSet::contains_at`.
    #[napi]
    pub fn is_indexed_at(&self, address: String, contract_name: String, block_number: i64) -> bool {
        let store = self.read();
        let (Some(key), Some(contract_idx)) = (
            address_key(store.ecosystem, &address),
            store.contract_idx(&contract_name),
        ) else {
            return false;
        };
        store.is_indexed_at(&key, contract_idx, block_number)
    }

    /// Drops every address registered after `target_block`, returning how many
    /// were dropped. Ids are tombstoned rather than reused, so a set built
    /// before the rollback keeps pointing at the right entries; the fetch state
    /// re-derives its partitions from filtered sets straight after.
    #[napi]
    pub fn rollback(&self, target_block: i64) -> i64 {
        let mut store = self.inner.write().unwrap();
        let mut removed = 0;
        for id in 0..store.entries.len() {
            let entry = &store.entries[id];
            if entry.dead || entry.registration_block <= target_block {
                continue;
            }
            let key = entry.key.clone();
            let contract_idx = entry.contract_idx as usize;
            store.entries[id].dead = true;
            store.id_by_key.remove(&key);
            store.live_count_by_contract[contract_idx] -= 1;
            removed += 1;
        }
        // A pending write whose entry just died must never reach the database:
        // the refetch registers the address afresh under a new id.
        let live_unwritten = std::mem::take(&mut store.unwritten)
            .into_iter()
            .filter(|&id| !store.entry(id).dead)
            .collect();
        store.unwritten = live_unwritten;
        removed
    }

    /// The entry an address is registered under, whichever contract holds it —
    /// addresses are unique chain-wide. `None` once rolled back.
    #[napi]
    pub fn get(&self, address: String) -> Option<AddressEntry> {
        let store = self.read();
        let key = address_key(store.ecosystem, &address)?;
        let id = store.live_id(&key)?;
        let entry = store.entry(id);
        Some(AddressEntry {
            address: address_string(store.ecosystem, &entry.key),
            contract_name: store.contract_name(entry.contract_idx).to_string(),
            registration_block: entry.registration_block,
            effective_start_block: entry.effective_start_block,
        })
    }

    /// Canonical strings for every address registered under one contract, in set
    /// order. Used by `chain.<Contract>.addresses` and by tests.
    #[napi]
    pub fn contract_addresses(&self, contract_name: String) -> Vec<String> {
        let store = self.read();
        match store.contract_idx(&contract_name) {
            None => Vec::new(),
            Some(contract_idx) => store
                .sorted_live_ids(0, |entry| entry.contract_idx == contract_idx)
                .into_iter()
                .map(|id| address_string(store.ecosystem, &store.entry(id).key))
                .collect(),
        }
    }
}

impl AddressStore {
    fn with_ecosystem(ecosystem: Ecosystem, contracts: Vec<AddressStoreContract>) -> Self {
        let mut contract_names = Vec::with_capacity(contracts.len());
        let mut contract_start_blocks = Vec::with_capacity(contracts.len());
        let mut contract_idx_by_name = HashMap::with_capacity(contracts.len());
        let mut contract_depends_on_addresses = Vec::with_capacity(contracts.len());
        for contract in contracts {
            if contract_idx_by_name.contains_key(&contract.name) {
                continue;
            }
            contract_idx_by_name.insert(contract.name.clone(), contract_names.len() as u32);
            contract_names.push(contract.name);
            contract_start_blocks.push(contract.start_block.unwrap_or(0).max(0));
            contract_depends_on_addresses.push(contract.depends_on_addresses);
        }
        let live_count_by_contract = vec![0u32; contract_names.len()];
        Self {
            inner: Arc::new(RwLock::new(StoreInner {
                ecosystem,
                contract_names,
                contract_start_blocks,
                contract_depends_on_addresses,
                contract_idx_by_name,
                entries: Vec::new(),
                id_by_key: HashMap::new(),
                live_count_by_contract,
                unwritten: Vec::new(),
            })),
        }
    }

    fn read(&self) -> RwLockReadGuard<'_, StoreInner> {
        self.inner.read().unwrap()
    }

    /// Shared handle for the source clients, which hold the store for the
    /// lifetime of the chain and read it while routing responses.
    pub fn handle(&self) -> Arc<RwLock<StoreInner>> {
        self.inner.clone()
    }

    /// Rejects the whole batch before applying any of it: an unknown contract
    /// name is a bug upstream, and a caller that survives the error must not
    /// find the earlier registrations already applied.
    fn register_all(
        &self,
        registrations: Vec<AddressRegistration>,
        track_unwritten: bool,
    ) -> napi::Result<Vec<RegistrationVerdict>> {
        let mut store = self.inner.write().unwrap();
        for reg in registrations.iter() {
            if store.contract_idx(&reg.contract_name).is_none() {
                return Err(napi::Error::from_reason(format!(
                    "Address {} registered for contract \"{}\", which the chain doesn't index.",
                    reg.address, reg.contract_name
                )));
            }
        }
        Ok(registrations
            .iter()
            .map(|reg| store.register_one(reg, track_unwritten))
            .collect())
    }
}

impl StoreInner {
    /// Infallible: `register_all` has already rejected every unknown contract
    /// name, so nothing here can fail partway through a batch.
    fn register_one(
        &mut self,
        reg: &AddressRegistration,
        track_unwritten: bool,
    ) -> RegistrationVerdict {
        let Some(key) = address_key(self.ecosystem, &reg.address) else {
            return RegistrationVerdict {
                kind: VERDICT_INVALID.to_string(),
                fetchable: false,
                effective_start_block: 0,
                existing_contract_name: None,
                existing_effective_start_block: None,
            };
        };

        let contract_idx = self
            .contract_idx(&reg.contract_name)
            .expect("register_all validates every contract name before applying the batch");
        let contract_start_block = self.contract_start_blocks[contract_idx as usize];
        let effective_start_block =
            derive_effective_start_block(reg.registration_block, contract_start_block);

        if let Some(id) = self.live_id(&key) {
            let entry = self.entry(id);
            let existing_contract_name = self.contract_name(entry.contract_idx).to_string();
            let kind = if existing_contract_name == reg.contract_name {
                VERDICT_DUPLICATE
            } else {
                VERDICT_CONFLICT
            };
            return RegistrationVerdict {
                kind: kind.to_string(),
                fetchable: false,
                effective_start_block,
                existing_effective_start_block: Some(entry.effective_start_block),
                existing_contract_name: Some(existing_contract_name),
            };
        }

        let id = self.entries.len() as u64;
        self.id_by_key.insert(key.clone(), id);
        self.entries.push(Entry {
            key,
            contract_idx,
            registration_block: reg.registration_block,
            effective_start_block,
            dead: false,
        });
        self.live_count_by_contract[contract_idx as usize] += 1;
        if track_unwritten {
            self.unwritten.push(id);
        }
        RegistrationVerdict {
            kind: VERDICT_ADDED.to_string(),
            fetchable: self.contract_depends_on_addresses[contract_idx as usize],
            effective_start_block,
            existing_contract_name: None,
            existing_effective_start_block: None,
        }
    }
}

fn apply_window(ids: &[u64], offset: Option<i64>, limit: Option<i64>) -> Vec<u64> {
    let start = offset.unwrap_or(0).max(0) as usize;
    if start >= ids.len() {
        return Vec::new();
    }
    let end = match limit {
        Some(limit) if limit <= 0 => start,
        Some(limit) => start.saturating_add(limit as usize).min(ids.len()),
        None => ids.len(),
    };
    ids[start..end].to_vec()
}

/// Ids must already be in set order, so equal start blocks are adjacent.
fn group_start_blocks(store: &StoreInner, ids: &[u64]) -> Vec<StartBlockGroup> {
    let mut groups: Vec<StartBlockGroup> = Vec::new();
    for &id in ids {
        let start_block = store.entry(id).effective_start_block;
        match groups.last_mut() {
            Some(last) if last.start_block == start_block => last.count += 1,
            _ => groups.push(StartBlockGroup {
                start_block,
                count: 1,
            }),
        }
    }
    groups
}

/// One contract's slice of a set, materialised in set order: the strings a
/// query's address filter needs and their padded topic forms for events that
/// filter an indexed address param by `chain.<Contract>.addresses`.
pub struct ContractSlice {
    pub name: String,
    pub contract_idx: u32,
    pub addresses: Vec<String>,
    pub topics: Vec<String>,
}

/// Everything derived from a set's ids, built once on first use. A partition
/// makes many queries from one set, and both the query builder and the router
/// read this — so the padded topics and the owner index are computed once per
/// set rather than once per query.
pub struct SetCache {
    contracts: Vec<ContractSlice>,
    index_by_name: HashMap<String, usize>,
    owner_by_key: HashMap<Key, usize>,
    len: usize,
}

impl SetCache {
    pub fn slice(&self, contract_name: &str) -> Option<&ContractSlice> {
        self.index_by_name
            .get(contract_name)
            .map(|&idx| &self.contracts[idx])
    }

    /// The contract owning an address, by the raw bytes the source handed back
    /// (EVM/Fuel address bytes, an SVM `programId`'s base58 bytes). `None` means
    /// the address isn't in this partition — the log routes to wildcards only.
    pub fn owner_of(&self, key: &[u8]) -> Option<&str> {
        self.owner_by_key
            .get(key)
            .map(|&idx| self.contracts[idx].name.as_str())
    }

    pub fn len(&self) -> usize {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }
}

/// A snapshot: the ids are fixed at construction, so a rollback that tombstones
/// an entry leaves sets built before it still holding that id. Only
/// `filter_by_registration_block` prunes those — everything else
/// (`addresses`, `entries`, `slice`, `merge`, the cache) reports them, on
/// purpose. A rollback rebuilds the fetch state's partitions from filtered sets
/// straight after, and a stale set that outlives that still can't fetch a dead
/// address: `is_indexed_at` answers `false` for it, so every router drops the
/// items it would bring back. Pruning here instead would shift the offsets
/// `start_block_groups` hands to `slice` mid-flight.
#[napi]
pub struct AddressSet {
    store: Arc<RwLock<StoreInner>>,
    /// Ordered by `(effectiveStartBlock, address bytes)`.
    ids: Arc<[u64]>,
    cache: OnceLock<Arc<SetCache>>,
}

#[napi]
impl AddressSet {
    #[napi]
    pub fn size(&self) -> i64 {
        self.ids.len() as i64
    }

    /// Whether this set holds the address under `contract_name` and it has
    /// already started at `block_number` — the gate a real source's router
    /// applies to a server-side address-filtered query: ownership answered by
    /// the partition's own set, the temporal half by the store (a merged
    /// partition's addresses don't all start at the same block).
    #[napi]
    pub fn contains_at(&self, address: String, contract_name: String, block_number: i64) -> bool {
        let store = self.store.read().unwrap();
        let (Some(key), Some(contract_idx)) = (
            address_key(store.ecosystem, &address),
            store.contract_idx(&contract_name),
        ) else {
            return false;
        };
        let indexed = store.is_indexed_at(&key, contract_idx, block_number);
        drop(store);
        indexed && self.cache().owner_of(&key) == Some(contract_name.as_str())
    }

    /// How many of one contract's addresses this set holds.
    #[napi]
    pub fn count_for(&self, contract_name: String) -> i64 {
        self.cache()
            .slice(&contract_name)
            .map_or(0, |slice| slice.addresses.len() as i64)
    }

    #[napi]
    pub fn contract_names(&self) -> Vec<String> {
        self.cache()
            .contracts
            .iter()
            .map(|slice| slice.name.clone())
            .collect()
    }

    /// Distinct effective start blocks in this set, ascending.
    #[napi]
    pub fn start_block_groups(&self) -> Vec<StartBlockGroup> {
        let store = self.store.read().unwrap();
        group_start_blocks(&store, &self.ids)
    }

    #[napi]
    pub fn slice(&self, offset: i64, limit: Option<i64>) -> AddressSet {
        let ids = apply_window(&self.ids, Some(offset), limit);
        AddressSet::new(self.store.clone(), ids)
    }

    /// Keeps only the named contracts' addresses, in set order.
    #[napi]
    pub fn filter_by_contracts(&self, contract_names: Vec<String>) -> AddressSet {
        let store = self.store.read().unwrap();
        let kept: std::collections::HashSet<u32> = contract_names
            .iter()
            .filter_map(|name| store.contract_idx(name))
            .collect();
        let ids = self
            .ids
            .iter()
            .copied()
            .filter(|&id| kept.contains(&store.entry(id).contract_idx))
            .collect();
        drop(store);
        AddressSet::new(self.store.clone(), ids)
    }

    /// Drops addresses registered after `target_block`, and any the store has
    /// since tombstoned. Ordering is preserved, so the result is still a valid
    /// set without re-sorting.
    #[napi]
    pub fn filter_by_registration_block(&self, target_block: i64) -> AddressSet {
        let store = self.store.read().unwrap();
        let ids: Vec<u64> = self
            .ids
            .iter()
            .copied()
            .filter(|&id| {
                let entry = store.entry(id);
                !entry.dead && entry.registration_block <= target_block
            })
            .collect();
        drop(store);
        AddressSet::new(self.store.clone(), ids)
    }

    /// Union with another set of the same store, keeping set order. Duplicate
    /// ids collapse, so merging overlapping partitions can't double-count.
    #[napi]
    pub fn merge(&self, other: &AddressSet) -> AddressSet {
        // Not a debug assert: ids are store-scoped, so a foreign id silently
        // indexes into the wrong entry — or out of bounds — and the query
        // built from the result fetches addresses nobody registered.
        assert!(
            Arc::ptr_eq(&self.store, &other.store),
            "merging address sets from different stores",
        );
        let store = self.store.read().unwrap();
        let (left, right) = (&self.ids, &other.ids);
        let mut ids = Vec::with_capacity(left.len() + right.len());
        let (mut i, mut j) = (0, 0);
        while i < left.len() && j < right.len() {
            match store.sort_key(left[i]).cmp(&store.sort_key(right[j])) {
                std::cmp::Ordering::Less => {
                    ids.push(left[i]);
                    i += 1;
                }
                std::cmp::Ordering::Greater => {
                    ids.push(right[j]);
                    j += 1;
                }
                // Same address: one id, taken once.
                std::cmp::Ordering::Equal => {
                    ids.push(left[i]);
                    i += 1;
                    j += 1;
                }
            }
        }
        ids.extend_from_slice(&left[i..]);
        ids.extend_from_slice(&right[j..]);
        drop(store);
        AddressSet::new(self.store.clone(), ids)
    }

    /// Canonical strings in set order, for `chain.<Contract>.addresses` and
    /// assertions. Never on a query path — queries read the cached slices.
    #[napi]
    pub fn addresses(&self) -> Vec<String> {
        let store = self.store.read().unwrap();
        self.ids
            .iter()
            .map(|&id| address_string(store.ecosystem, &store.entry(id).key))
            .collect()
    }

    #[napi]
    pub fn entries(&self) -> Vec<AddressEntry> {
        let store = self.store.read().unwrap();
        self.ids
            .iter()
            .map(|&id| {
                let entry = store.entry(id);
                AddressEntry {
                    address: address_string(store.ecosystem, &entry.key),
                    contract_name: store.contract_name(entry.contract_idx).to_string(),
                    registration_block: entry.registration_block,
                    effective_start_block: entry.effective_start_block,
                }
            })
            .collect()
    }
}

impl AddressSet {
    fn new(store: Arc<RwLock<StoreInner>>, ids: Vec<u64>) -> Self {
        Self {
            store,
            ids: ids.into(),
            cache: OnceLock::new(),
        }
    }

    pub fn cache(&self) -> &Arc<SetCache> {
        self.cache.get_or_init(|| {
            let store = self.store.read().unwrap();
            let mut contracts: Vec<ContractSlice> = Vec::new();
            let mut index_by_contract_idx: HashMap<u32, usize> = HashMap::new();
            let mut owner_by_key = HashMap::with_capacity(self.ids.len());
            for &id in self.ids.iter() {
                let entry = store.entry(id);
                let slot = *index_by_contract_idx
                    .entry(entry.contract_idx)
                    .or_insert_with(|| {
                        contracts.push(ContractSlice {
                            name: store.contract_name(entry.contract_idx).to_string(),
                            contract_idx: entry.contract_idx,
                            addresses: Vec::new(),
                            topics: Vec::new(),
                        });
                        contracts.len() - 1
                    });
                contracts[slot]
                    .addresses
                    .push(address_string(store.ecosystem, &entry.key));
                if matches!(store.ecosystem, Ecosystem::Evm { .. }) {
                    contracts[slot].topics.push(address_topic(&entry.key));
                }
                owner_by_key.insert(entry.key.clone(), slot);
            }
            let index_by_name = contracts
                .iter()
                .enumerate()
                .map(|(idx, slice)| (slice.name.clone(), idx))
                .collect();
            Arc::new(SetCache {
                contracts,
                index_by_name,
                owner_by_key,
                len: self.ids.len(),
            })
        })
    }

    pub fn store(&self) -> &Arc<RwLock<StoreInner>> {
        &self.store
    }
}

#[cfg(test)]
impl AddressStore {
    /// `seed_batch` for tests, which never register an unknown contract name.
    pub(crate) fn register_seed(
        &self,
        registrations: Vec<AddressRegistration>,
    ) -> Vec<RegistrationVerdict> {
        self.seed_batch(registrations).unwrap()
    }
}

/// Store scaffolding for the source modules' routing tests, which need a real
/// store because every address gate reads one.
#[cfg(test)]
pub(crate) mod test_support {
    use super::*;

    fn store_of(ecosystem: Ecosystem, entries: &[(&str, &[&str])]) -> AddressStore {
        let store = AddressStore::with_ecosystem(
            ecosystem,
            entries
                .iter()
                .map(|(name, _)| AddressStoreContract {
                    name: name.to_string(),
                    start_block: None,
                    depends_on_addresses: true,
                })
                .collect(),
        );
        let registrations = entries
            .iter()
            .flat_map(|(name, addresses)| {
                addresses.iter().map(|address| AddressRegistration {
                    address: address.to_string(),
                    contract_name: name.to_string(),
                    // A config address: effective from block 0, so tests only
                    // opt into the temporal gate when they set a start block.
                    registration_block: -1,
                })
            })
            .collect();
        for verdict in store.register_seed(registrations) {
            assert_eq!(verdict.kind, VERDICT_ADDED, "test fixture address rejected");
        }
        store
    }

    /// A store over `entries`' contracts, with each contract's addresses
    /// registered as config addresses.
    pub(crate) fn evm_store(entries: &[(&str, &[&str])]) -> AddressStore {
        store_of(
            Ecosystem::Evm {
                should_checksum: false,
            },
            entries,
        )
    }

    pub(crate) fn fuel_store(entries: &[(&str, &[&str])]) -> AddressStore {
        store_of(Ecosystem::Fuel, entries)
    }

    pub(crate) fn svm_store(entries: &[(&str, &[&str])]) -> AddressStore {
        store_of(Ecosystem::Svm, entries)
    }

    /// Every live address the store holds, as one set — reachable from a store
    /// handle alone, for routing tests that keep only the handle their client
    /// cloned.
    pub(crate) fn full_set(handle: &Arc<RwLock<StoreInner>>) -> AddressSet {
        let ids = handle.read().unwrap().sorted_live_ids(0, |_| true);
        let set = AddressSet::new(handle.clone(), ids);
        let _ = set.cache();
        set
    }

    /// One set spanning every named contract's addresses, with its cache
    /// materialised — routing helpers read the cache while holding the store
    /// guard, and initialising it there would take the same lock twice.
    pub(crate) fn set_of(store: &AddressStore, contract_names: &[&str]) -> AddressSet {
        let set = contract_names.iter().fold(store.empty_set(), |acc, name| {
            acc.merge(&store.make_set(name.to_string(), None))
        });
        let _ = set.cache();
        set
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "0x00000000000000000000000000000000000000aa";
    const B: &str = "0x00000000000000000000000000000000000000bb";
    const C: &str = "0x00000000000000000000000000000000000000cc";

    fn contracts(entries: &[(&str, Option<i64>)]) -> Vec<AddressStoreContract> {
        entries
            .iter()
            .map(|(name, start_block)| AddressStoreContract {
                name: name.to_string(),
                start_block: *start_block,
                depends_on_addresses: true,
            })
            .collect()
    }

    /// A contract nothing on this chain fetches by address — either it has no
    /// events here, or they're all wildcard. Registered and persisted like any
    /// other, never fetched.
    fn address_independent_contract(name: &str) -> AddressStoreContract {
        AddressStoreContract {
            name: name.to_string(),
            start_block: None,
            depends_on_addresses: false,
        }
    }

    fn reg(address: &str, contract_name: &str, registration_block: i64) -> AddressRegistration {
        AddressRegistration {
            address: address.to_string(),
            contract_name: contract_name.to_string(),
            registration_block,
        }
    }

    fn store() -> AddressStore {
        AddressStore::new_evm(false, contracts(&[("C", Some(100)), ("D", None)]))
    }

    fn kinds(verdicts: &[RegistrationVerdict]) -> Vec<&str> {
        verdicts.iter().map(|v| v.kind.as_str()).collect()
    }

    fn set_entries(set: &AddressSet) -> Vec<(String, String, i64, i64)> {
        set.entries()
            .into_iter()
            .map(|e| {
                (
                    e.address,
                    e.contract_name,
                    e.registration_block,
                    e.effective_start_block,
                )
            })
            .collect()
    }

    #[test]
    fn derives_effective_start_block_from_contract_and_registration() {
        let store = store();
        let verdicts = store.register_seed(vec![
            // Config address of a contract starting at 100.
            reg(A, "C", -1),
            // Dynamic registration below the contract start block.
            reg(B, "C", 50),
            // Dynamic registration for a contract with no start block.
            reg(C, "D", 70),
        ]);
        assert_eq!(
            verdicts
                .iter()
                .map(|v| (v.kind.as_str(), v.effective_start_block))
                .collect::<Vec<_>>(),
            vec![("added", 100), ("added", 100), ("added", 70)]
        );
    }

    #[test]
    fn duplicate_and_conflict_carry_the_existing_registration() {
        let store = store();
        let verdicts = store.register_seed(vec![
            reg(A, "C", 10),
            // Same address, same contract — duplicate, with what's already held.
            reg(A, "C", 20),
            // Same address, different contract — conflict.
            reg(A, "D", 20),
            // Conflict inside one batch, against an address added moments ago.
            reg(B, "C", 30),
            reg(B, "D", 30),
        ]);
        assert_eq!(
            verdicts
                .iter()
                .map(|v| (
                    v.kind.as_str(),
                    v.existing_contract_name.as_deref(),
                    v.existing_effective_start_block
                ))
                .collect::<Vec<_>>(),
            vec![
                ("added", None, None),
                ("duplicate", Some("C"), Some(100)),
                ("conflict", Some("C"), Some(100)),
                ("added", None, None),
                ("conflict", Some("C"), Some(100)),
            ]
        );
    }

    #[test]
    fn an_address_belongs_to_one_contract_whether_or_not_it_is_fetched() {
        // "D" stands in for a contract nothing on this chain fetches by
        // address: the store treats it like any other, and the fetch state
        // decides nothing is queried for it.
        let store = store();
        let verdicts = store.register_seed(vec![reg(A, "D", 10), reg(A, "C", 20), reg(A, "D", 30)]);
        assert_eq!(
            (
                kinds(&verdicts),
                store.size(),
                store.contract_addresses("D".to_string()),
            ),
            (
                vec!["added", "conflict", "duplicate"],
                1,
                vec![A.to_string()]
            )
        );
    }

    #[test]
    fn registering_for_a_contract_the_chain_doesnt_index_is_an_error() {
        let store = store();
        assert!(store.register_batch(vec![reg(A, "Unknown", 10)]).is_err());
        assert!(store.seed_batch(vec![reg(A, "Unknown", 10)]).is_err());
    }

    #[test]
    fn a_batch_with_an_unknown_name_applies_none_of_itself() {
        let store = store();
        assert!(store
            .register_batch(vec![reg(A, "C", 10), reg(B, "Unknown", 20)])
            .is_err());
        // The valid registration ahead of the bad one must not have landed —
        // a caller that survives the error would otherwise see a store holding
        // an address it was never told about.
        assert_eq!((store.size(), store.pending_entries().len()), (0, 0));
    }

    #[test]
    fn only_an_address_dependent_contract_is_fetchable() {
        let store = AddressStore::new_evm(
            false,
            vec![
                contracts(&[("C", None)]).remove(0),
                address_independent_contract("D"),
            ],
        );
        let verdicts = store.register_seed(vec![reg(A, "C", 10), reg(B, "D", 20)]);
        assert_eq!(
            verdicts.iter().map(|v| v.fetchable).collect::<Vec<_>>(),
            vec![true, false]
        );
    }

    #[test]
    fn contract_addresses_are_listed_per_contract_in_set_order() {
        let store = AddressStore::new_evm(false, contracts(&[("C", None), ("D", None)]));
        let verdicts = store.register_seed(vec![reg(B, "C", 20), reg(A, "C", 10), reg(C, "D", 30)]);
        assert_eq!(
            (
                kinds(&verdicts),
                store.contract_addresses("C".to_string()),
                store.contract_addresses("D".to_string()),
                store.contract_addresses("Missing".to_string()),
            ),
            (
                vec!["added", "added", "added"],
                // Set order: A(10) before B(20).
                vec![A.to_string(), B.to_string()],
                vec![C.to_string()],
                vec![],
            )
        );
    }

    fn drained(
        store: &AddressStore,
        to_block: i64,
        checkpoints: &[i64],
    ) -> Vec<(String, i64, u32)> {
        store
            .drain_for_write(to_block, checkpoints.to_vec())
            .unwrap()
            .into_iter()
            .map(|e| (e.address, e.registration_block, e.checkpoint_idx))
            .collect()
    }

    #[test]
    fn unwritten_entries_drain_up_to_the_written_block() {
        let store = store();
        store.register_seed(vec![reg(A, "C", 100)]);
        store
            .register_batch(vec![reg(B, "C", 200), reg(C, "C", 400)])
            .unwrap();

        assert_eq!(
            (
                // The seeded address is already stored, so it never drains.
                drained(&store, 300, &[100, 200]),
                drained(&store, 300, &[100, 200]),
                drained(&store, 400, &[400]),
            ),
            (
                vec![(B.to_string(), 200, 1)],
                vec![],
                vec![(C.to_string(), 400, 0)]
            )
        );
    }

    #[test]
    fn draining_without_a_checkpoint_errors_and_keeps_the_queue() {
        let store = store();
        store
            .register_batch(vec![reg(A, "C", 100), reg(B, "C", 200)])
            .unwrap();

        // Block 200 has no checkpoint: the batch never processed the event that
        // registered B, so the row would be unreachable by a rollback.
        assert!(store.drain_for_write(300, vec![100]).is_err());
        // Nothing was consumed, so a retry with the right checkpoints still
        // sees both — the failed drain didn't silently swallow A.
        assert_eq!(
            drained(&store, 300, &[100, 200]),
            vec![(A.to_string(), 100, 0), (B.to_string(), 200, 1)]
        );
    }

    #[test]
    fn rollback_drops_pending_writes_of_the_addresses_it_kills() {
        let store = store();
        store
            .register_batch(vec![reg(A, "C", 100), reg(B, "C", 400)])
            .unwrap();
        store.rollback(200);
        // Re-registering after the rollback makes the address pending again.
        store.register_batch(vec![reg(B, "C", 500)]).unwrap();

        assert_eq!(
            drained(&store, 1000, &[100, 500]),
            vec![(A.to_string(), 100, 0), (B.to_string(), 500, 1)]
        );
    }

    #[test]
    fn checksummed_and_lowercase_spellings_are_one_address() {
        let store = AddressStore::new_evm(true, contracts(&[("C", None)]));
        let verdicts = store.register_seed(vec![
            reg("0x85149247691df622eaf1a8bd0cafd40bc45154a9", "C", 1),
            reg("0x85149247691df622eaF1a8Bd0CaFd40BC45154a9", "C", 2),
        ]);
        assert_eq!(
            (kinds(&verdicts), store.contract_addresses("C".to_string())),
            (
                vec!["added", "duplicate"],
                // Rendered checksummed, matching what the sources hand back.
                vec!["0x85149247691df622eaF1a8Bd0CaFd40BC45154a9".to_string()]
            )
        );
    }

    #[test]
    fn malformed_address_is_rejected_not_registered() {
        let store = store();
        let verdicts = store.register_seed(vec![reg("not-an-address", "C", 1)]);
        assert_eq!((kinds(&verdicts), store.size()), (vec!["invalid"], 0));
    }

    #[test]
    fn set_order_is_independent_of_registration_order() {
        // The same addresses registered in three different orders (and split
        // across batches differently) must produce byte-identical sets — that's
        // what lets a restored indexer rebuild the partitions it had.
        let expected = {
            let store = store();
            store.register_seed(vec![reg(A, "C", 30), reg(B, "C", 10), reg(C, "C", 20)]);
            set_entries(&store.make_set("C".to_string(), None))
        };

        let reversed = {
            let store = store();
            store.register_seed(vec![reg(C, "C", 20), reg(B, "C", 10), reg(A, "C", 30)]);
            set_entries(&store.make_set("C".to_string(), None))
        };

        let split_batches = {
            let store = store();
            store.register_seed(vec![reg(B, "C", 10)]);
            store.register_seed(vec![reg(A, "C", 30)]);
            store.register_seed(vec![reg(C, "C", 20)]);
            set_entries(&store.make_set("C".to_string(), None))
        };

        assert_eq!(
            (&reversed, &split_batches),
            (&expected, &expected),
            "set order must be derived from (effectiveStartBlock, address), not insertion order",
        );
    }

    #[test]
    fn min_id_selects_only_a_batch_additions() {
        let store = store();
        store.register_seed(vec![reg(A, "C", 10)]);
        let cursor = store.next_id();
        store.register_seed(vec![reg(B, "C", 20), reg(C, "C", 30)]);
        let added = store.make_set(
            "C".to_string(),
            Some(MakeSetOptions {
                min_id: Some(cursor),
                ..Default::default()
            }),
        );
        assert_eq!(added.addresses(), vec![B.to_string(), C.to_string()]);
    }

    #[test]
    fn start_block_windows_and_grouping() {
        let store = store();
        store.register_seed(vec![reg(A, "C", 300), reg(B, "C", 100), reg(C, "C", 300)]);
        let window = store.make_set(
            "C".to_string(),
            Some(MakeSetOptions {
                from_start_block: Some(300),
                ..Default::default()
            }),
        );
        assert_eq!(
            (
                store
                    .start_block_groups("C".to_string())
                    .into_iter()
                    .map(|g| (g.start_block, g.count))
                    .collect::<Vec<_>>(),
                window.addresses(),
            ),
            (
                // 100 is the contract's start block, which B's registration
                // block of 100 also lands on.
                vec![(100, 1), (300, 2)],
                vec![A.to_string(), C.to_string()],
            )
        );
    }

    #[test]
    fn merge_and_slice_keep_set_order_and_dedupe() {
        let store = store();
        store.register_seed(vec![reg(A, "C", 300), reg(B, "C", 100), reg(C, "D", 200)]);
        let c_set = store.make_set("C".to_string(), None);
        let d_set = store.make_set("D".to_string(), None);
        let merged = c_set.merge(&d_set).merge(&c_set);
        assert_eq!(
            (
                merged.addresses(),
                merged.slice(1, Some(1)).addresses(),
                merged.count_for("C".to_string()),
                merged.count_for("D".to_string()),
            ),
            (
                // Ordered by effectiveStartBlock: B(100), C(200), A(300).
                vec![B.to_string(), C.to_string(), A.to_string()],
                vec![C.to_string()],
                2,
                1,
            )
        );
    }

    #[test]
    fn rollback_tombstones_and_filters_existing_sets() {
        let store = store();
        store.register_seed(vec![reg(A, "C", 100), reg(B, "C", 300), reg(C, "C", 500)]);
        let before = store.make_set("C".to_string(), None);
        let removed = store.rollback(300);
        assert_eq!(
            (
                removed,
                store.contract_count("C".to_string()),
                before.filter_by_registration_block(300).addresses(),
                store.make_set("C".to_string(), None).addresses(),
            ),
            (
                1,
                2,
                vec![A.to_string(), B.to_string()],
                vec![A.to_string(), B.to_string()],
            )
        );
    }

    #[test]
    fn a_set_built_before_a_rollback_keeps_tombstones_but_cant_fetch_them() {
        let store = store();
        store.register_seed(vec![reg(A, "C", 100), reg(B, "C", 500)]);
        // Cache the set before the rollback too, the way a partition that is
        // mid-query would have.
        let before = store.make_set("C".to_string(), None);
        let _ = before.cache();
        store.rollback(300);
        assert_eq!(
            (
                // Still listed: only filter_by_registration_block prunes.
                before.addresses(),
                before.size(),
                // But dead to every router, whichever gate it applies.
                before.contains_at(B.to_string(), "C".to_string(), 600),
                store.is_indexed_at(B.to_string(), "C".to_string(), 600),
                before.filter_by_registration_block(300).addresses(),
            ),
            (
                vec![A.to_string(), B.to_string()],
                2,
                false,
                false,
                vec![A.to_string()],
            )
        );
    }

    #[test]
    #[should_panic(expected = "merging address sets from different stores")]
    fn merging_sets_from_different_stores_panics() {
        let left = store();
        let right = store();
        left.register_seed(vec![reg(A, "C", 100)]);
        right.register_seed(vec![reg(B, "C", 100)]);
        let _ = left
            .make_set("C".to_string(), None)
            .merge(&right.make_set("C".to_string(), None));
    }

    #[test]
    fn rolled_back_address_can_be_registered_again() {
        let store = store();
        store.register_seed(vec![reg(A, "C", 500)]);
        store.rollback(300);
        let verdicts = store.register_seed(vec![reg(A, "D", 400)]);
        assert_eq!(
            (kinds(&verdicts), store.contract_addresses("D".to_string())),
            (vec!["added"], vec![A.to_string()])
        );
    }

    #[test]
    fn is_indexed_at_gates_on_contract_and_effective_start_block() {
        let store = store();
        store.register_seed(vec![reg(A, "C", 300)]);
        assert_eq!(
            (
                store.is_indexed_at(A.to_string(), "C".to_string(), 300),
                store.is_indexed_at(A.to_string(), "C".to_string(), 299),
                store.is_indexed_at(A.to_string(), "D".to_string(), 300),
                store.is_indexed_at(B.to_string(), "C".to_string(), 300),
            ),
            (true, false, false, false)
        );
    }

    #[test]
    fn contains_at_scopes_the_gate_to_the_set() {
        let store = store();
        store.register_seed(vec![reg(A, "C", 300), reg(B, "C", 300)]);
        let set = store.make_set_of(vec![A.to_string()]);
        assert_eq!(
            (
                set.contains_at(A.to_string(), "C".to_string(), 300),
                set.contains_at(A.to_string(), "C".to_string(), 299),
                set.contains_at(A.to_string(), "D".to_string(), 300),
                // Registered for the same contract, but held by another set;
                // only the chain-wide gate on the store answers for it.
                set.contains_at(B.to_string(), "C".to_string(), 300),
                store.is_indexed_at(B.to_string(), "C".to_string(), 300),
            ),
            (true, false, false, false, true)
        );
    }

    #[test]
    fn set_cache_indexes_owners_and_padded_topics() {
        let store = store();
        store.register_seed(vec![reg(A, "C", 100), reg(C, "D", 200)]);
        let set = store
            .make_set("C".to_string(), None)
            .merge(&store.make_set("D".to_string(), None));
        let cache = set.cache();
        let a_key = address_key(
            Ecosystem::Evm {
                should_checksum: false,
            },
            A,
        )
        .unwrap();
        assert_eq!(
            (
                cache.owner_of(&a_key),
                cache.slice("C").map(|s| s.topics.clone()),
                cache.slice("Missing").is_none(),
                cache.len(),
            ),
            (
                Some("C"),
                Some(vec![
                    "0x00000000000000000000000000000000000000000000000000000000000000aa"
                        .to_string()
                ]),
                true,
                2,
            )
        );
    }

    #[test]
    fn svm_keys_on_the_base58_text() {
        let store = AddressStore::new_svm(contracts(&[("P", None)]));
        let program = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
        let verdicts = store.register_seed(vec![reg(program, "P", 5)]);
        assert_eq!(
            (
                kinds(&verdicts),
                store.contract_addresses("P".to_string()),
                store.is_indexed_at(program.to_string(), "P".to_string(), 5),
            ),
            (vec!["added"], vec![program.to_string()], true)
        );
    }
}
