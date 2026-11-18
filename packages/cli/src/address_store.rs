use std::collections::{HashMap, HashSet};
use std::sync::{Arc, OnceLock, RwLock, RwLockReadGuard};

use napi::bindgen_prelude::Buffer;
use napi_derive::napi;

use crate::address_columns::{Entries, Id, KeyIndex};
use crate::chain_buffer::Ecosystem;

/// Binary form of an address, the identity the store keys on.
///
/// EVM and Fuel addresses are hex-decoded (20 and 32 bytes), so a checksummed
/// spelling and a lowercase one are the same key. SVM pubkeys keep their base58
/// bytes: that encoding is already canonical and case-sensitive, so decoding
/// would buy nothing and would cost a decode per routed instruction — where the
/// raw `programId` string is what the source hands us.
type Key = Box<[u8]>;

/// The fixed key width of an ecosystem, or `None` for SVM — whose base58 keys
/// are the address text itself and vary in length.
fn key_width(ecosystem: Ecosystem) -> Option<usize> {
    match ecosystem {
        Ecosystem::Evm => Some(20),
        Ecosystem::Fuel => Some(32),
        Ecosystem::Svm => None,
    }
}

/// The binary key for an address string, or `None` when it isn't a well-formed
/// address for the ecosystem. Callers surface that as an `invalid` verdict
/// rather than throwing: a malformed dynamic registration should be skipped
/// with a warning, not take the indexer down.
fn address_key(ecosystem: Ecosystem, address: &str) -> Option<Key> {
    match key_width(ecosystem) {
        Some(width) => crate::hex::decode_fixed(address, width).map(|b| b.into_boxed_slice()),
        None => (!address.is_empty()).then(|| address.as_bytes().to_vec().into_boxed_slice()),
    }
}

/// Render a key back to its canonical string: lowercase hex for the hex
/// ecosystems, the base58 text itself for SVM. Everything the store hands back
/// is spelled this way — a query's address filter, a log line, a rejected row —
/// except at the one user-facing boundary below.
fn address_string(ecosystem: Ecosystem, key: &[u8]) -> String {
    match ecosystem {
        Ecosystem::Evm | Ecosystem::Fuel => format!("0x{}", faster_hex::hex_string(key)),
        Ecosystem::Svm => String::from_utf8_lossy(key).into_owned(),
    }
}

/// Render a key the way the indexer shows addresses to the user, following the
/// chain's `lowercaseAddresses` setting — the spelling `chain.<Contract>.addresses`
/// answers with, and the one every address the sources hand back is encoded in.
/// The caller supplies the setting, because the store holds keys, not spellings.
fn shown_address_string(ecosystem: Ecosystem, should_checksum: bool, key: &[u8]) -> String {
    match ecosystem {
        Ecosystem::Evm if should_checksum => {
            let bytes = <[u8; 20]>::try_from(key).expect("EVM key width");
            alloy_primitives::Address::from(bytes).to_checksum(None)
        }
        _ => address_string(ecosystem, key),
    }
}

/// A user-supplied EVM address: `0x` and 40 hex digits. Any digit casing is
/// accepted — a checksum is recomputed, never verified — but unlike
/// `hex::decode_fixed` an uppercase `0X` prefix is not.
pub(crate) fn parse_evm_address(address: &str) -> Option<[u8; 20]> {
    let digits = address.strip_prefix("0x")?;
    if digits.len() != 40 {
        return None;
    }
    let mut key = [0u8; 20];
    faster_hex::hex_decode(digits.as_bytes(), &mut key).ok()?;
    Some(key)
}

#[napi]
pub fn normalize_evm_address(address: String, should_checksum: bool) -> Option<String> {
    parse_evm_address(&address)
        .map(|key| shown_address_string(Ecosystem::Evm, should_checksum, &key))
}

/// Left-pad an EVM address to its 32-byte indexed-topic form, as lowercase hex.
fn address_topic(key: &[u8]) -> String {
    let mut topic = [0u8; 32];
    topic[32 - key.len()..].copy_from_slice(key);
    format!("0x{}", faster_hex::hex_string(&topic))
}

#[cfg_attr(test, allow(dead_code))]
fn ecosystem_by_name(name: &str) -> napi::Result<Ecosystem> {
    match name {
        "evm" => Ok(Ecosystem::Evm),
        "fuel" => Ok(Ecosystem::Fuel),
        "svm" => Ok(Ecosystem::Svm),
        _ => Err(napi::Error::from_reason(format!(
            "Unknown ecosystem \"{name}\"."
        ))),
    }
}

/// Encodes address strings to their store keys, one buffer per address. The one
/// encoder: config addresses reach storage through here, so the bytes a row
/// holds and the bytes a store keys on can't fork.
#[cfg_attr(test, allow(dead_code))]
#[napi]
pub fn encode_addresses(ecosystem: String, addresses: Vec<String>) -> napi::Result<Vec<Buffer>> {
    let ecosystem = ecosystem_by_name(&ecosystem)?;
    addresses
        .iter()
        .map(|address| {
            address_key(ecosystem, address)
                .map(|key| key.to_vec().into())
                .ok_or_else(|| {
                    napi::Error::from_reason(format!(
                        "Address \"{address}\" is not a valid address."
                    ))
                })
        })
        .collect()
}

/// Walks a packed address column, yielding one key slice per row. Every column
/// carries its keys' lengths, so this is also where a column that doesn't hold
/// what it claims — a key of the wrong width for the ecosystem, or bytes the
/// lengths don't account for — is rejected rather than decoded into keys that
/// can never match a log address.
fn key_slices<'a>(
    ecosystem: Ecosystem,
    bytes: &'a [u8],
    lengths: &[u32],
) -> napi::Result<Vec<&'a [u8]>> {
    let fixed_width = key_width(ecosystem);
    let mut total = 0;
    for &length in lengths {
        let width = length as usize;
        if let Some(expected) = fixed_width {
            if width != expected {
                return Err(napi::Error::from_reason(format!(
                    "Address keys are {expected} bytes, but a row claims {width}."
                )));
            }
        }
        total += width;
    }
    if total != bytes.len() {
        return Err(napi::Error::from_reason(format!(
            "Packed addresses are {} bytes, but their keys account for {total}.",
            bytes.len()
        )));
    }

    // Every key is now known to sit inside the buffer, so the walk can't run off
    // the end.
    let mut slices = Vec::with_capacity(lengths.len());
    let mut offset = 0;
    for &length in lengths {
        let width = length as usize;
        slices.push(&bytes[offset..offset + width]);
        offset += width;
    }
    Ok(slices)
}

/// Renders packed address keys back to the canonical strings the JS side shows.
/// The inverse of `encode_addresses`, and the only decoder.
#[cfg_attr(test, allow(dead_code))]
#[napi]
pub fn render_addresses(
    ecosystem: String,
    should_checksum: bool,
    bytes: Buffer,
    lengths: Vec<u32>,
) -> napi::Result<Vec<String>> {
    let ecosystem = ecosystem_by_name(&ecosystem)?;
    Ok(key_slices(ecosystem, &bytes, &lengths)?
        .into_iter()
        .map(|key| shown_address_string(ecosystem, should_checksum, key))
        .collect())
}

/// The addresses of one contract inside a packed column of seeded rows, as
/// canonical strings — what `chain.<Contract>.addresses` answers before the
/// indexer state exists and the resumed rows are all there is.
#[cfg_attr(test, allow(dead_code))]
#[napi]
pub fn render_contract_addresses(
    ecosystem: String,
    should_checksum: bool,
    bytes: Buffer,
    lengths: Vec<u32>,
    contract_ids: Vec<u32>,
    contract_id: u32,
) -> napi::Result<Vec<String>> {
    let ecosystem = ecosystem_by_name(&ecosystem)?;
    let keys = key_slices(ecosystem, &bytes, &lengths)?;
    if keys.len() != contract_ids.len() {
        return Err(napi::Error::from_reason(format!(
            "Packed addresses hold {} keys but {} contract ids.",
            keys.len(),
            contract_ids.len()
        )));
    }
    Ok(keys
        .into_iter()
        .zip(contract_ids)
        .filter(|&(_, id)| id == contract_id)
        .map(|(key, _)| shown_address_string(ecosystem, should_checksum, key))
        .collect())
}

/// The config's contract names in canonical order — their position is the id
/// `envio_contracts` stores and every address row references. Byte order, so
/// the ids never depend on the order contracts happen to be declared in.
#[cfg_attr(test, allow(dead_code))]
#[napi]
pub fn canonical_contract_names(mut names: Vec<String>) -> Vec<String> {
    names.sort_unstable_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
    names.dedup();
    names
}

/// `max(max(registrationBlock, 0), contractStartBlock)` — a config address
/// (registration block -1) starts at its contract's start block, a dynamic one
/// no earlier than the block that registered it.
fn derive_effective_start_block(registration_block: i64, contract_start_block: i64) -> i64 {
    registration_block.max(0).max(contract_start_block)
}

/// One registration, read off the store's columns.
#[derive(Clone, Copy)]
struct Entry<'a> {
    key: &'a [u8],
    contract_idx: u32,
    registration_block: i64,
    effective_start_block: i64,
}

pub struct StoreInner {
    ecosystem: Ecosystem,
    contract_names: Vec<String>,
    contract_start_blocks: Vec<i64>,
    contract_depends_on_addresses: Vec<bool>,
    contract_idx_by_name: HashMap<String, u32>,
    entries: Entries,
    index: KeyIndex,
    live_count_by_contract: Vec<u32>,
    /// Dynamic registrations not yet persisted to `envio_addresses`, in
    /// registration order. Drained by `drain_for_write` when the batch covering
    /// their registration block is written.
    unwritten: Vec<Id>,
}

impl StoreInner {
    fn entry(&self, id: Id) -> Entry<'_> {
        let contract_idx = self.entries.contract_idx(id);
        let registration_block = self.entries.registration_block(id);
        Entry {
            key: self.entries.key(id),
            contract_idx,
            registration_block,
            effective_start_block: derive_effective_start_block(
                registration_block,
                self.contract_start_blocks[contract_idx as usize],
            ),
        }
    }

    fn contract_name(&self, idx: u32) -> &str {
        &self.contract_names[idx as usize]
    }

    /// Sort key giving a set its id-independent order.
    fn sort_key(&self, id: Id) -> (i64, &[u8], u32) {
        let entry = self.entry(id);
        (entry.effective_start_block, entry.key, entry.contract_idx)
    }

    fn live_id_for(&self, key: &[u8], contract_idx: u32) -> Option<Id> {
        let mut cursor = self.index.head(key, &self.entries);
        while let Some(id) = cursor {
            if self.entries.contract_idx(id) == contract_idx {
                return Some(id);
            }
            cursor = self.index.next(id);
        }
        None
    }

    /// The gate every address-dependent registration applies to a matched
    /// item: the address is registered for this contract and its effective
    /// start block is at or before the item's block.
    pub fn is_indexed_at(&self, key: &[u8], contract_idx: u32, block_number: i64) -> bool {
        self.live_id_for(key, contract_idx)
            .is_some_and(|id| self.entry(id).effective_start_block <= block_number)
    }

    pub fn contract_idx(&self, name: &str) -> Option<u32> {
        self.contract_idx_by_name.get(name).copied()
    }

    fn sorted_ids(&self, mut ids: Vec<Id>) -> Vec<Id> {
        ids.sort_unstable_by(|&a, &b| self.sort_key(a).cmp(&self.sort_key(b)));
        ids
    }

    /// Live ids from `min_id` up that `keep` accepts, in set order.
    fn sorted_live_ids(&self, min_id: Id, keep: impl Fn(&Entry) -> bool) -> Vec<Id> {
        let ids = (min_id..self.entries.len() as Id)
            .filter(|&id| !self.entries.is_dead(id) && keep(&self.entry(id)))
            .collect();
        self.sorted_ids(ids)
    }

    /// Infallible: `register_all` has already rejected every unknown contract
    /// name and out-of-range block, so nothing here can fail partway through a
    /// batch.
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
                existing_effective_start_block: None,
            };
        };
        let contract_idx = self
            .contract_idx(&reg.contract_name)
            .expect("register_all validates every contract name before applying the batch");
        let effective_start_block = derive_effective_start_block(
            reg.registration_block,
            self.contract_start_blocks[contract_idx as usize],
        );
        if let Some(id) = self.live_id_for(&key, contract_idx) {
            return RegistrationVerdict {
                kind: VERDICT_DUPLICATE.to_string(),
                fetchable: false,
                effective_start_block,
                existing_effective_start_block: Some(self.entry(id).effective_start_block),
            };
        }
        let id = self.insert(&key, contract_idx, reg.registration_block);
        if track_unwritten {
            self.unwritten.push(id);
        }
        RegistrationVerdict {
            kind: VERDICT_ADDED.to_string(),
            fetchable: self.contract_depends_on_addresses[contract_idx as usize],
            effective_start_block,
            existing_effective_start_block: None,
        }
    }

    /// Registers a row read back from storage, whose key is already the store's
    /// own encoding. Returns the rejection to warn about, or `None` when the
    /// row landed.
    fn seed_one(
        &mut self,
        key: &[u8],
        contract_idx: u32,
        registration_block: i64,
    ) -> Option<RejectedRow> {
        let effective_start_block = derive_effective_start_block(
            registration_block,
            self.contract_start_blocks[contract_idx as usize],
        );
        if let Some(id) = self.live_id_for(key, contract_idx) {
            return Some(RejectedRow {
                address: address_string(self.ecosystem, key),
                contract_name: self.contract_name(contract_idx).to_string(),
                effective_start_block,
                existing_effective_start_block: self.entry(id).effective_start_block,
            });
        }
        self.insert(key, contract_idx, registration_block);
        None
    }

    fn insert(&mut self, key: &[u8], contract_idx: u32, registration_block: i64) -> Id {
        let id = self
            .entries
            .push(key, contract_idx as u16, registration_block as i32);
        self.index.insert(id, &self.entries);
        self.live_count_by_contract[contract_idx as usize] += 1;
        id
    }
}

/// A registration block the columns hold: -1 for a config address, else a
/// block number, which the runtime keeps in 32 bits.
fn check_registration_block(registration_block: i64) -> napi::Result<()> {
    if (-1..=i64::from(i32::MAX)).contains(&registration_block) {
        Ok(())
    } else {
        Err(napi::Error::from_reason(format!(
            "Address registration block {registration_block} is out of range."
        )))
    }
}

#[napi(object)]
pub struct AddressStoreContract {
    pub name: String,
    pub start_block: Option<i64>,
    pub depends_on_addresses: bool,
}

#[napi(object)]
pub struct AddressRegistration {
    pub address: String,
    pub contract_name: String,
    /// -1 for a config address.
    pub registration_block: i64,
}

#[napi(object)]
pub struct RegistrationVerdict {
    pub kind: String,
    pub fetchable: bool,
    pub effective_start_block: i64,
    pub existing_effective_start_block: Option<i64>,
}

pub const VERDICT_ADDED: &str = "added";
pub const VERDICT_DUPLICATE: &str = "duplicate";
pub const VERDICT_INVALID: &str = "invalid";

#[napi(object)]
pub struct StartBlockGroup {
    pub start_block: i64,
    pub count: i64,
}

#[napi(object)]
pub struct RolledBackAddress {
    pub address: Buffer,
    pub contract_id: u32,
}

#[napi(object)]
pub struct DrainedAddress {
    pub address: Buffer,
    pub contract_id: u32,
    pub registration_block: i64,
    pub checkpoint_idx: u32,
}

#[napi(object)]
pub struct RejectedRow {
    pub address: String,
    pub contract_name: String,
    pub effective_start_block: i64,
    pub existing_effective_start_block: i64,
}

#[napi(object)]
pub struct ContractAddressCount {
    pub contract_name: String,
    pub count: i64,
}

#[napi(object)]
#[derive(Default)]
pub struct MakeSetOptions {
    pub min_id: Option<i64>,
    pub from_start_block: Option<i64>,
    pub to_start_block: Option<i64>,
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
    pub fn new_evm(contracts: Vec<AddressStoreContract>) -> napi::Result<Self> {
        Self::with_ecosystem(Ecosystem::Evm, contracts)
    }

    #[napi(factory)]
    pub fn new_svm(contracts: Vec<AddressStoreContract>) -> napi::Result<Self> {
        Self::with_ecosystem(Ecosystem::Svm, contracts)
    }

    #[napi(factory)]
    pub fn new_fuel(contracts: Vec<AddressStoreContract>) -> napi::Result<Self> {
        Self::with_ecosystem(Ecosystem::Fuel, contracts)
    }

    /// The id the next added address will get. Captured before a batch, it
    /// becomes the `minId` that selects exactly that batch's additions.
    #[napi]
    pub fn next_id(&self) -> i64 {
        self.read().entries.len() as i64
    }

    /// Registers a batch of dynamic registrations, resolving each address
    /// against both the store and the batch's own earlier entries, so the same
    /// address registered twice for one contract inside a single batch is a
    /// duplicate just as it is across batches. What it adds is marked pending
    /// persistence.
    #[napi]
    pub fn register_batch(
        &self,
        registrations: Vec<AddressRegistration>,
    ) -> napi::Result<Vec<RegistrationVerdict>> {
        self.register_all(registrations, true)
    }

    /// Registers rows the database already holds, columnar: one packed buffer of
    /// address keys with their `lengths`, plus the parallel contract ids and
    /// registration blocks. The only way in for a stored address — config ones
    /// and the dynamic ones a resume restores — and nothing it adds is marked
    /// pending, so nothing is ever written back. Only the (defensive)
    /// rejections come back rendered.
    #[napi]
    pub fn seed_rows(
        &self,
        addresses: Buffer,
        lengths: Vec<u32>,
        contract_ids: Vec<u32>,
        registration_blocks: Vec<i64>,
    ) -> napi::Result<Vec<RejectedRow>> {
        let mut store = self.inner.write().unwrap();
        let count = contract_ids.len();
        if lengths.len() != count || registration_blocks.len() != count {
            return Err(napi::Error::from_reason(format!(
                "Seeded address columns disagree: {count} contract ids, {} address lengths, {} \
                 registration blocks.",
                lengths.len(),
                registration_blocks.len()
            )));
        }
        for &contract_idx in &contract_ids {
            if contract_idx as usize >= store.contract_names.len() {
                return Err(napi::Error::from_reason(format!(
                    "Seeded address row names contract id {contract_idx}, which the chain's \
                     store doesn't hold."
                )));
            }
        }
        for &registration_block in &registration_blocks {
            check_registration_block(registration_block)?;
        }
        let keys = key_slices(store.ecosystem, &addresses, &lengths)?;
        Ok(keys
            .into_iter()
            .enumerate()
            .filter_map(|(row, key)| {
                store.seed_one(key, contract_ids[row], registration_blocks[row])
            })
            .collect())
    }

    /// Drains the registrations awaiting persistence whose registration block is
    /// at or below `to_block_inclusive` — everything the batch being written
    /// covers — pairing each with the checkpoint at its registration block.
    /// What sits above that block stays pending for a later batch.
    ///
    /// A drained registration with no checkpoint at its block means it came from
    /// an event this batch never processed, so the caller has no write to
    /// attribute it to. That errors with the queue untouched, so the caller can
    /// fail without the store having lied about what is still pending.
    #[napi]
    pub fn drain_for_write(
        &self,
        to_block_inclusive: i64,
        checkpoint_block_numbers: Vec<i64>,
    ) -> napi::Result<Vec<DrainedAddress>> {
        let mut store = self.inner.write().unwrap();
        let checkpoint_by_block: HashMap<i64, u32> = checkpoint_block_numbers
            .iter()
            .enumerate()
            .rev()
            .map(|(idx, &block)| (block, idx as u32))
            .collect();
        let mut drained = Vec::new();
        let mut pending = Vec::new();
        for &id in store.unwritten.iter() {
            let entry = store.entry(id);
            if entry.registration_block > to_block_inclusive {
                pending.push(id);
                continue;
            }
            let Some(&checkpoint_idx) = checkpoint_by_block.get(&entry.registration_block) else {
                return Err(napi::Error::from_reason(format!(
                    "Registered address {} at block {} has no checkpoint in the batch that writes \
                     it.",
                    address_string(store.ecosystem, entry.key),
                    entry.registration_block
                )));
            };
            drained.push(DrainedAddress {
                address: entry.key.to_vec().into(),
                contract_id: entry.contract_idx,
                registration_block: entry.registration_block,
                checkpoint_idx,
            });
        }
        store.unwritten = pending;
        Ok(drained)
    }

    /// How many registrations await persistence.
    #[napi]
    pub fn pending_count(&self) -> i64 {
        self.read().unwritten.len() as i64
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
                let min_id = options.min_id.unwrap_or(0).clamp(0, i64::from(Id::MAX)) as Id;
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

    /// A set holding nothing — what an address-free (wildcard) partition
    /// carries, so every partition is queried through the same handle.
    #[napi]
    pub fn empty_set(&self) -> AddressSet {
        AddressSet::new(self.inner.clone(), Vec::new())
    }

    /// Live registration counts for the contracts this chain has something to
    /// say about — one it fetches by address, or one it holds addresses for.
    /// Every store holds every contract of every chain, so reporting all of
    /// them would give each chain a series per contract it never sees.
    #[napi]
    pub fn contract_counts(&self) -> Vec<ContractAddressCount> {
        let store = self.read();
        store
            .contract_names
            .iter()
            .enumerate()
            .filter(|(idx, _)| {
                store.contract_depends_on_addresses[*idx] || store.live_count_by_contract[*idx] > 0
            })
            .map(|(idx, name)| ContractAddressCount {
                contract_name: name.clone(),
                count: i64::from(store.live_count_by_contract[idx]),
            })
            .collect()
    }

    #[napi]
    pub fn contract_count(&self, contract_name: String) -> i64 {
        let store = self.read();
        store.contract_idx(&contract_name).map_or(0, |idx| {
            i64::from(store.live_count_by_contract[idx as usize])
        })
    }

    /// The bytes the store's registrations and their index hold.
    #[napi]
    pub fn heap_bytes(&self) -> f64 {
        let store = self.read();
        (store.entries.heap_bytes() + store.index.heap_bytes() + store.unwritten.capacity() * 4)
            as f64
    }

    /// Every live registration across every contract — the count the chain
    /// reports as `numAddresses`. An address registered for two contracts
    /// counts twice, once per registration.
    #[napi]
    pub fn size(&self) -> i64 {
        self.read()
            .live_count_by_contract
            .iter()
            .map(|&count| i64::from(count))
            .sum()
    }

    /// Whether an address is registered for a contract and already started at
    /// `block_number` — the chain-wide gate, exposed for the simulate source,
    /// which has no real query boundary to gate at.
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

    /// Drops every address registered after `target_block`, returning the
    /// registrations the database has to delete with it. Ids are tombstoned
    /// rather than reused, so a set built before the rollback keeps pointing at
    /// the right entries; the fetch state re-derives its partitions from
    /// filtered sets straight after.
    ///
    /// Only registrations the database may already hold are reported: one still
    /// queued for insert never reached it, and config addresses are never
    /// dropped at all (their registration block is below every target).
    #[napi]
    pub fn rollback(&self, target_block: i64) -> Vec<RolledBackAddress> {
        let mut guard = self.inner.write().unwrap();
        let store = &mut *guard;
        let pending_insert: HashSet<Id> = store.unwritten.iter().copied().collect();
        let mut rolled_back = Vec::new();
        for id in 0..store.entries.len() as Id {
            if store.entries.is_dead(id) || store.entries.registration_block(id) <= target_block {
                continue;
            }
            let contract_idx = store.entries.contract_idx(id);
            // Only this registration leaves the key's index: the same address
            // registered for another contract survives the rollback.
            store.index.remove(id, &store.entries);
            store.entries.kill(id);
            store.live_count_by_contract[contract_idx as usize] -= 1;
            if !pending_insert.contains(&id) {
                rolled_back.push(RolledBackAddress {
                    address: store.entries.key(id).to_vec().into(),
                    contract_id: contract_idx,
                });
            }
        }
        // A pending write whose entry just died must never reach the database:
        // the refetch registers the address afresh under a new id.
        let entries = &store.entries;
        store.unwritten.retain(|&id| !entries.is_dead(id));
        rolled_back
    }

    /// Contract names holding at least one dynamically registered address. The
    /// fetch state reads it to know which contracts need dynamic-contract
    /// partitions after a seed.
    #[napi]
    pub fn dynamic_contract_names(&self) -> Vec<String> {
        let store = self.read();
        let mut seen = vec![false; store.contract_names.len()];
        for id in 0..store.entries.len() as Id {
            if !store.entries.is_dead(id) && store.entries.registration_block(id) != -1 {
                seen[store.entries.contract_idx(id) as usize] = true;
            }
        }
        seen.iter()
            .enumerate()
            .filter(|(_, &has)| has)
            .map(|(idx, _)| store.contract_names[idx].clone())
            .collect()
    }

    /// Every address registered under one contract, in set order, spelled the
    /// way the chain shows addresses — what `chain.<Contract>.addresses` answers
    /// with.
    #[napi]
    pub fn contract_addresses(&self, contract_name: String, should_checksum: bool) -> Vec<String> {
        let store = self.read();
        match store.contract_idx(&contract_name) {
            None => Vec::new(),
            Some(contract_idx) => store
                .sorted_live_ids(0, |entry| entry.contract_idx == contract_idx)
                .into_iter()
                .map(|id| {
                    shown_address_string(store.ecosystem, should_checksum, store.entries.key(id))
                })
                .collect(),
        }
    }
}

impl AddressStore {
    fn with_ecosystem(
        ecosystem: Ecosystem,
        contracts: Vec<AddressStoreContract>,
    ) -> napi::Result<Self> {
        if contracts.len() > usize::from(u16::MAX) {
            return Err(napi::Error::from_reason(format!(
                "The address store holds at most {} contracts, not {}.",
                u16::MAX,
                contracts.len()
            )));
        }
        let mut contract_names = Vec::with_capacity(contracts.len());
        let mut contract_start_blocks = Vec::with_capacity(contracts.len());
        let mut contract_idx_by_name = HashMap::with_capacity(contracts.len());
        let mut contract_depends_on_addresses = Vec::with_capacity(contracts.len());
        for contract in contracts {
            if contract_idx_by_name.contains_key(&contract.name) {
                return Err(napi::Error::from_reason(format!(
                    "Contract \"{}\" is listed twice in the address store's contract list.",
                    contract.name,
                )));
            }
            contract_idx_by_name.insert(contract.name.clone(), contract_names.len() as u32);
            contract_names.push(contract.name);
            contract_start_blocks.push(contract.start_block.unwrap_or(0).max(0));
            contract_depends_on_addresses.push(contract.depends_on_addresses);
        }
        let live_count_by_contract = vec![0u32; contract_names.len()];
        Ok(Self {
            inner: Arc::new(RwLock::new(StoreInner {
                ecosystem,
                contract_names,
                contract_start_blocks,
                contract_depends_on_addresses,
                contract_idx_by_name,
                entries: Entries::new(key_width(ecosystem)),
                index: KeyIndex::default(),
                live_count_by_contract,
                unwritten: Vec::new(),
            })),
        })
    }

    fn read(&self) -> RwLockReadGuard<'_, StoreInner> {
        self.inner.read().unwrap()
    }

    /// Shared handle for the matchers, which hold the store for the lifetime
    /// of the chain and read it while matching rows.
    pub fn handle(&self) -> Arc<RwLock<StoreInner>> {
        self.inner.clone()
    }

    /// Rejects the whole batch before applying any of it: an unknown contract
    /// name or an out-of-range block is a bug upstream, and a caller that
    /// survives the error must not find the earlier registrations already
    /// applied.
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
            check_registration_block(reg.registration_block)?;
        }
        Ok(registrations
            .iter()
            .map(|reg| store.register_one(reg, track_unwritten))
            .collect())
    }
}

fn apply_window(ids: &[Id], offset: Option<i64>, limit: Option<i64>) -> Vec<Id> {
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
fn group_start_blocks(store: &StoreInner, ids: &[Id]) -> Vec<StartBlockGroup> {
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

/// One contract's addresses in a set, rendered for a query: the strings an
/// address filter takes and, for EVM, their padded topic forms.
#[derive(Default)]
pub struct ContractAddresses {
    pub addresses: Vec<String>,
    pub topics: Vec<String>,
}

/// A set's addresses by contract, rendered for one query. Rendered per query
/// rather than kept: a set of thousands renders in about a millisecond, and
/// keeping the strings would cost every partition hundreds of bytes per
/// address.
pub struct RenderedSet {
    by_contract: HashMap<String, ContractAddresses>,
}

impl RenderedSet {
    pub fn slice(&self, contract_name: &str) -> Option<&ContractAddresses> {
        self.by_contract.get(contract_name)
    }
}

/// A snapshot: the ids are fixed at construction, so a rollback that tombstones
/// an entry leaves sets built before it still holding that id. Only
/// `filter_by_registration_block` prunes those — everything else reports them,
/// on purpose. A rollback rebuilds the fetch state's partitions from filtered
/// sets straight after, and a stale set that outlives that still can't fetch a
/// dead address: `is_indexed_at` answers `false` for it, so matching drops the
/// items it would bring back. Pruning here instead would shift the offsets
/// `start_block_groups` hands to `slice` mid-flight.
#[napi]
pub struct AddressSet {
    store: Arc<RwLock<StoreInner>>,
    ids: Arc<[Id]>,
    /// Each contract's address count, in the order the contracts first appear.
    counts: OnceLock<Vec<(u32, u32)>>,
}

#[napi]
impl AddressSet {
    #[napi]
    pub fn size(&self) -> i64 {
        self.ids.len() as i64
    }

    /// Whether this set holds the address under `contract_name` and it has
    /// already started at `block_number`, the gate the mock and simulate
    /// sources apply to a partition's query: ownership answered by the set, the
    /// temporal half by the store (a merged partition's addresses don't all
    /// start at the same block).
    #[napi]
    pub fn contains_at(&self, address: String, contract_name: String, block_number: i64) -> bool {
        let store = self.store.read().unwrap();
        let (Some(key), Some(contract_idx)) = (
            address_key(store.ecosystem, &address),
            store.contract_idx(&contract_name),
        ) else {
            return false;
        };
        store.is_indexed_at(&key, contract_idx, block_number)
            && self.ids.iter().any(|&id| {
                store.entries.contract_idx(id) == contract_idx && store.entries.key(id) == &*key
            })
    }

    /// How many of one contract's addresses this set holds.
    #[napi]
    pub fn count_for(&self, contract_name: String) -> i64 {
        let Some(contract_idx) = self.store.read().unwrap().contract_idx(&contract_name) else {
            return 0;
        };
        self.counts()
            .iter()
            .find(|(idx, _)| *idx == contract_idx)
            .map_or(0, |(_, count)| i64::from(*count))
    }

    #[napi]
    pub fn contract_names(&self) -> Vec<String> {
        let store = self.store.read().unwrap();
        self.counts()
            .iter()
            .map(|(idx, _)| store.contract_name(*idx).to_string())
            .collect()
    }

    /// The set's addresses in set order, spelled canonically: what a query
    /// built from the set asks for.
    #[napi]
    pub fn addresses(&self) -> Vec<String> {
        let store = self.store.read().unwrap();
        self.ids
            .iter()
            .map(|&id| address_string(store.ecosystem, store.entries.key(id)))
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
        let kept: HashSet<u32> = contract_names
            .iter()
            .filter_map(|name| store.contract_idx(name))
            .collect();
        let ids = self
            .ids
            .iter()
            .copied()
            .filter(|&id| kept.contains(&store.entries.contract_idx(id)))
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
        let ids = self
            .ids
            .iter()
            .copied()
            .filter(|&id| {
                !store.entries.is_dead(id) && store.entries.registration_block(id) <= target_block
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
                // Equal sort keys, including contract_idx: one id.
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
}

impl AddressSet {
    fn new(store: Arc<RwLock<StoreInner>>, ids: Vec<Id>) -> Self {
        Self {
            store,
            ids: ids.into(),
            counts: OnceLock::new(),
        }
    }

    fn counts(&self) -> &[(u32, u32)] {
        self.counts.get_or_init(|| {
            let store = self.store.read().unwrap();
            let mut counts: Vec<(u32, u32)> = Vec::new();
            for &id in self.ids.iter() {
                let contract_idx = store.entries.contract_idx(id);
                match counts.iter_mut().find(|(idx, _)| *idx == contract_idx) {
                    Some((_, count)) => *count += 1,
                    None => counts.push((contract_idx, 1)),
                }
            }
            counts
        })
    }

    /// Every address the store holds for `contract_names`, each contract on
    /// its own, in set order, as sets of at most `max_addresses` each. A chunk
    /// holding one contract becomes one request rather than one per contract.
    pub fn contract_chunks(&self, contract_names: &[String], max_addresses: usize) -> Vec<Self> {
        let store = self.store.read().unwrap();
        let ids_by_contract: Vec<Vec<Id>> = contract_names
            .iter()
            .filter_map(|name| store.contract_idx(name))
            .map(|contract_idx| {
                store.sorted_live_ids(0, |entry| entry.contract_idx == contract_idx)
            })
            .collect();
        drop(store);
        ids_by_contract
            .iter()
            .flat_map(|ids| ids.chunks(max_addresses.max(1)))
            .map(|chunk| Self::new(self.store.clone(), chunk.to_vec()))
            .collect()
    }

    /// The set's addresses by contract, in set order, rendered for a query.
    pub fn render(&self) -> RenderedSet {
        let store = self.store.read().unwrap();
        let mut by_contract: HashMap<String, ContractAddresses> = HashMap::new();
        for &id in self.ids.iter() {
            let entry = store.entry(id);
            let rendered = by_contract
                .entry(store.contract_name(entry.contract_idx).to_string())
                .or_default();
            rendered
                .addresses
                .push(address_string(store.ecosystem, entry.key));
            if store.ecosystem == Ecosystem::Evm {
                rendered.topics.push(address_topic(entry.key));
            }
        }
        RenderedSet { by_contract }
    }

    pub fn store(&self) -> &Arc<RwLock<StoreInner>> {
        &self.store
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
        )
        .unwrap();
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
        for verdict in store.register_all(registrations, false).unwrap() {
            assert_eq!(verdict.kind, VERDICT_ADDED, "test fixture address rejected");
        }
        store
    }

    /// A store over `entries`' contracts, with each contract's addresses
    /// registered as config addresses.
    pub(crate) fn evm_store(entries: &[(&str, &[&str])]) -> AddressStore {
        store_of(Ecosystem::Evm, entries)
    }

    pub(crate) fn fuel_store(entries: &[(&str, &[&str])]) -> AddressStore {
        store_of(Ecosystem::Fuel, entries)
    }

    pub(crate) fn svm_store(entries: &[(&str, &[&str])]) -> AddressStore {
        store_of(Ecosystem::Svm, entries)
    }

    /// One set spanning every named contract's addresses.
    pub(crate) fn set_of(store: &AddressStore, contract_names: &[&str]) -> AddressSet {
        contract_names.iter().fold(store.empty_set(), |acc, name| {
            acc.merge(&store.make_set(name.to_string(), None))
        })
    }
}
