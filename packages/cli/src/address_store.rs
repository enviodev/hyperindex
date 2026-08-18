//! Per-chain address index, kept in Rust. Every address the chain indexes —
//! config-declared or dynamically registered — lives here once per contract it
//! is registered for, keyed by its binary form so a checksummed and a lowercase
//! spelling of the same EVM address can't diverge. The store owns registration
//! bookkeeping (duplicate detection, `effectiveStartBlock` derivation, reorg
//! rollback) and hands out `AddressSet` handles: immutable, ordered snapshots
//! that a fetch-state partition carries instead of a JS address array.
//!
//! Identity is `(address, contract)`, not the address alone: one address may be
//! registered for several contracts, and each registration keeps its own start
//! block, partition and routing.
//!
//! A set is ordered by `(effectiveStartBlock, address bytes, contract)` —
//! independent of the ids inside it, so the same registrations produce
//! byte-identical sets whatever order they were registered or restored in.
//! Everything a query derives from a set (padded topics, the routing owner
//! index, per-contract counts) is computed once on first use and shared by
//! every query the partition makes.

use std::collections::HashMap;
use std::sync::{Arc, OnceLock, RwLock, RwLockReadGuard};

use napi::bindgen_prelude::Buffer;
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
    crate::hex::decode_fixed(s, len).map(|bytes| bytes.into_boxed_slice())
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

/// The fixed key width of an ecosystem, or `None` for SVM — whose base58 keys
/// are the address text itself and vary in length.
fn key_width(ecosystem: Ecosystem) -> Option<usize> {
    match ecosystem {
        Ecosystem::Evm { .. } => Some(20),
        Ecosystem::Fuel => Some(32),
        Ecosystem::Svm => None,
    }
}

fn ecosystem_by_name(name: &str, should_checksum: bool) -> napi::Result<Ecosystem> {
    match name {
        "evm" => Ok(Ecosystem::Evm { should_checksum }),
        "fuel" => Ok(Ecosystem::Fuel),
        "svm" => Ok(Ecosystem::Svm),
        _ => Err(napi::Error::from_reason(format!(
            "Unknown ecosystem \"{name}\"."
        ))),
    }
}

/// Address keys packed into one buffer — the columnar form `seed_rows` takes
/// and the write path binds to a `BYTEA[]`. `lengths` is present only for SVM,
/// whose keys vary in width.
#[napi(object)]
pub struct PackedAddresses {
    pub bytes: Buffer,
    pub lengths: Option<Vec<u32>>,
}

/// Encodes address strings to their store keys. The one encoder: config
/// addresses reach storage through here, so the bytes a row holds and the bytes
/// a store keys on can't fork.
#[napi]
pub fn pack_addresses(ecosystem: String, addresses: Vec<String>) -> napi::Result<PackedAddresses> {
    let ecosystem = ecosystem_by_name(&ecosystem, false)?;
    let mut bytes = Vec::new();
    let mut lengths = Vec::with_capacity(addresses.len());
    for address in addresses.iter() {
        let key = address_key(ecosystem, address).ok_or_else(|| {
            napi::Error::from_reason(format!("Address \"{address}\" is not a valid address."))
        })?;
        lengths.push(key.len() as u32);
        bytes.extend_from_slice(&key);
    }
    Ok(PackedAddresses {
        bytes: bytes.into(),
        lengths: key_width(ecosystem).is_none().then_some(lengths),
    })
}

/// Renders packed address keys back to the canonical strings the JS side shows.
/// The inverse of `pack_addresses`, and the only decoder.
#[napi]
pub fn render_addresses(
    ecosystem: String,
    should_checksum: bool,
    bytes: Buffer,
    lengths: Option<Vec<u32>>,
) -> napi::Result<Vec<String>> {
    let ecosystem = ecosystem_by_name(&ecosystem, should_checksum)?;
    let bytes: &[u8] = &bytes;
    let widths: Vec<usize> = match lengths {
        Some(lengths) => lengths.iter().map(|&len| len as usize).collect(),
        None => {
            let width = key_width(ecosystem).ok_or_else(|| {
                napi::Error::from_reason("SVM addresses can only be rendered with their lengths.")
            })?;
            if bytes.len() % width != 0 {
                return Err(napi::Error::from_reason(format!(
                    "Packed addresses of {} bytes don't divide into {width}-byte keys.",
                    bytes.len()
                )));
            }
            vec![width; bytes.len() / width]
        }
    };
    let mut rendered = Vec::with_capacity(widths.len());
    let mut offset = 0;
    for width in widths {
        if offset + width > bytes.len() {
            return Err(napi::Error::from_reason(
                "Packed addresses are shorter than their lengths claim.",
            ));
        }
        rendered.push(address_string(ecosystem, &bytes[offset..offset + width]));
        offset += width;
    }
    Ok(rendered)
}

/// The config's contract names in canonical order — their position is the id
/// `envio_contracts` stores and every address row references. Byte order, so
/// the ids never depend on the order contracts happen to be declared in.
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

struct Entry {
    key: Key,
    contract_idx: u32,
    registration_block: i64,
    effective_start_block: i64,
    /// Rolled back past its registration block. The slot stays so live ids
    /// never shift; the entry is unlinked from its key's chain so the address
    /// can be registered afresh for that contract.
    dead: bool,
    /// Next live entry registered for the same address under another contract.
    /// A chain rather than a per-key list keeps the common single-owner case
    /// free of a second allocation per address.
    next_by_key: Option<u64>,
}

pub struct StoreInner {
    ecosystem: Ecosystem,
    contract_names: Vec<String>,
    contract_start_blocks: Vec<i64>,
    contract_depends_on_addresses: Vec<bool>,
    contract_idx_by_name: HashMap<String, u32>,
    entries: Vec<Entry>,
    /// Head of each key's chain of live entries — one per contract the address
    /// is registered for.
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

    /// Sort key giving a set its id-independent order. At most one live entry
    /// exists per (address, contract), so `(effectiveStartBlock, bytes,
    /// contract)` is total over live entries.
    fn sort_key(&self, id: u64) -> (i64, &[u8], u32) {
        let entry = self.entry(id);
        (
            entry.effective_start_block,
            &entry.key,
            entry.contract_idx,
        )
    }

    /// Live ids registered for an address, one per owning contract.
    fn live_ids(&self, key: &[u8]) -> Vec<u64> {
        let mut ids = Vec::new();
        let mut cursor = self.id_by_key.get(key).copied();
        while let Some(id) = cursor {
            ids.push(id);
            cursor = self.entry(id).next_by_key;
        }
        ids
    }

    fn live_id_for(&self, key: &[u8], contract_idx: u32) -> Option<u64> {
        let mut cursor = self.id_by_key.get(key).copied();
        while let Some(id) = cursor {
            let entry = self.entry(id);
            if entry.contract_idx == contract_idx {
                return Some(id);
            }
            cursor = entry.next_by_key;
        }
        None
    }

    /// Drops a dead entry out of its key's chain, so the address can be
    /// registered for that contract again while its siblings stay live.
    fn unlink(&mut self, id: u64) {
        let key = self.entries[id as usize].key.clone();
        let next = self.entries[id as usize].next_by_key;
        self.entries[id as usize].next_by_key = None;
        match self.id_by_key.get(&key).copied() {
            Some(head) if head == id => match next {
                Some(next) => {
                    self.id_by_key.insert(key, next);
                }
                None => {
                    self.id_by_key.remove(&key);
                }
            },
            Some(head) => {
                let mut cursor = head;
                while let Some(candidate) = self.entries[cursor as usize].next_by_key {
                    if candidate == id {
                        self.entries[cursor as usize].next_by_key = next;
                        break;
                    }
                    cursor = candidate;
                }
            }
            None => (),
        }
    }

    /// The gate every address-dependent registration applies to a routed item:
    /// the address is registered for this contract and its effective start
    /// block is at or before the item's block.
    pub fn is_indexed_at(&self, key: &[u8], contract_idx: u32, block_number: i64) -> bool {
        match self.live_id_for(key, contract_idx) {
            Some(id) => self.entry(id).effective_start_block <= block_number,
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
    /// The contract's canonical id — its row in `envio_contracts`, and the
    /// `contract_idx` every entry and every persisted address row carries. The
    /// list must be ordered by it, so a stored id always names the same
    /// contract whichever chain's store reads it.
    pub id: u32,
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
/// turns `duplicate`/`invalid` into the user-facing warning.
#[napi(object)]
pub struct RegistrationVerdict {
    /// `added` | `duplicate` | `invalid`
    pub kind: String,
    /// Whether an `added` address is one this chain fetches for — the store
    /// answers it because the store is what holds the contract list. False for
    /// every rejected verdict.
    pub fetchable: bool,
    /// Derived for the incoming registration; 0 when the address was rejected.
    pub effective_start_block: i64,
    /// Set for `duplicate`, so the caller can warn when a later registration
    /// would have started earlier than the one already held.
    pub existing_effective_start_block: Option<i64>,
}

pub const VERDICT_ADDED: &str = "added";
pub const VERDICT_DUPLICATE: &str = "duplicate";
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
/// The address crosses as the raw store key — the same bytes the
/// `envio_addresses` row holds — so nothing outside this module encodes one.
#[napi(object)]
pub struct DrainedAddress {
    pub address: Buffer,
    pub contract_id: u32,
    pub registration_block: i64,
    /// Index into the `checkpoint_block_numbers` passed to `drain_for_write`.
    /// The ids themselves are bigints the caller already holds, so only the
    /// pairing crosses the boundary.
    pub checkpoint_idx: u32,
}

/// A seeded row the store refused, rendered for the caller's warning. Only the
/// rejections cross the boundary: a resume seeds millions of rows and gets back
/// a per-row verdict for none of them.
#[napi(object)]
pub struct RejectedRow {
    pub address: String,
    pub contract_name: String,
    /// `duplicate` | `invalid`
    pub kind: String,
    pub effective_start_block: i64,
    pub existing_effective_start_block: Option<i64>,
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

    /// `seed_batch` for rows read back from storage, columnar: one packed
    /// buffer of address keys (fixed-width for EVM and Fuel, `lengths` for
    /// SVM's variable base58 keys) plus the parallel contract ids and
    /// registration blocks. A resume seeds millions of rows, so nothing here
    /// allocates a string per row — the keys are already the store's own
    /// encoding, and only the (defensive) rejections come back rendered.
    #[napi]
    pub fn seed_rows(
        &self,
        addresses: Buffer,
        lengths: Option<Vec<u32>>,
        contract_ids: Vec<u32>,
        registration_blocks: Vec<i64>,
    ) -> napi::Result<Vec<RejectedRow>> {
        let mut store = self.inner.write().unwrap();
        let count = contract_ids.len();
        if registration_blocks.len() != count {
            return Err(napi::Error::from_reason(format!(
                "Seeded address columns disagree: {count} contract ids, {} registration blocks.",
                registration_blocks.len()
            )));
        }
        let bytes: &[u8] = &addresses;
        let widths: Vec<usize> = match &lengths {
            Some(lengths) => {
                if lengths.len() != count {
                    return Err(napi::Error::from_reason(format!(
                        "Seeded address columns disagree: {count} contract ids, {} address \
                         lengths.",
                        lengths.len()
                    )));
                }
                lengths.iter().map(|&len| len as usize).collect()
            }
            None => {
                let width = key_width(store.ecosystem).ok_or_else(|| {
                    napi::Error::from_reason(
                        "Seeded SVM addresses must carry their lengths: base58 keys are \
                         variable-width.",
                    )
                })?;
                vec![width; count]
            }
        };
        let total: usize = widths.iter().sum();
        if total != bytes.len() {
            return Err(napi::Error::from_reason(format!(
                "Seeded address bytes are {} long, but the {count} rows need {total}.",
                bytes.len()
            )));
        }

        let mut rejected = Vec::new();
        let mut offset = 0;
        for idx in 0..count {
            let key: Key = bytes[offset..offset + widths[idx]].to_vec().into_boxed_slice();
            offset += widths[idx];
            let contract_idx = contract_ids[idx];
            if contract_idx as usize >= store.contract_names.len() {
                return Err(napi::Error::from_reason(format!(
                    "Seeded address row names contract id {contract_idx}, which the chain's \
                     store doesn't hold."
                )));
            }
            if let Some(reason) = store.seed_one(key, contract_idx, registration_blocks[idx]) {
                rejected.push(reason);
            }
        }
        Ok(rejected)
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
                address: entry.key.to_vec().into(),
                contract_id: entry.contract_idx,
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
            .filter_map(|address| address_key(store.ecosystem, address))
            // Every contract the address is registered for, not just one of
            // them: a set built from addresses must hold the same entries the
            // contract-scoped selections would.
            .flat_map(|key| store.live_ids(&key))
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

    /// Every live registration across every contract — the count the chain
    /// reports as `numAddresses`. An address registered for two contracts
    /// counts twice, once per registration.
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
            let contract_idx = entry.contract_idx as usize;
            store.entries[id].dead = true;
            // Only this registration leaves the key's chain: the same address
            // registered for another contract survives the rollback.
            store.unlink(id as u64);
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

    /// Every entry an address is registered under, in set order — one per
    /// owning contract. Empty once every registration is rolled back.
    #[napi]
    pub fn get_all(&self, address: String) -> Vec<AddressEntry> {
        let store = self.read();
        let Some(key) = address_key(store.ecosystem, &address) else {
            return Vec::new();
        };
        store
            .sorted_ids(store.live_ids(&key))
            .into_iter()
            .map(|id| {
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

    /// Contract names holding at least one dynamically registered address. The
    /// fetch state reads it to know which contracts need dynamic-contract
    /// partitions after a seed.
    #[napi]
    pub fn dynamic_contract_names(&self) -> Vec<String> {
        let store = self.read();
        let mut seen = vec![false; store.contract_names.len()];
        for entry in store.entries.iter() {
            if !entry.dead && entry.registration_block != -1 {
                seen[entry.contract_idx as usize] = true;
            }
        }
        seen.iter()
            .enumerate()
            .filter(|(_, &has)| has)
            .map(|(idx, _)| store.contract_names[idx].clone())
            .collect()
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
            // Structural, not incidental: a `contract_idx` is written into
            // every persisted address row, so a list whose ids drifted from
            // its positions would attribute stored addresses to the wrong
            // contract on the next resume.
            assert_eq!(
                contract.id as usize,
                contract_names.len(),
                "address store contracts must be ordered by their canonical id",
            );
            assert!(
                !contract_idx_by_name.contains_key(&contract.name),
                "duplicate contract \"{}\" in the address store's contract list",
                contract.name,
            );
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
                existing_effective_start_block: None,
            };
        };

        let contract_idx = self
            .contract_idx(&reg.contract_name)
            .expect("register_all validates every contract name before applying the batch");
        let contract_start_block = self.contract_start_blocks[contract_idx as usize];
        let effective_start_block =
            derive_effective_start_block(reg.registration_block, contract_start_block);

        // Only the same address under the *same* contract is a duplicate: two
        // contracts may each index one address, each with its own start block.
        if let Some(id) = self.live_id_for(&key, contract_idx) {
            return RegistrationVerdict {
                kind: VERDICT_DUPLICATE.to_string(),
                fetchable: false,
                effective_start_block,
                existing_effective_start_block: Some(self.entry(id).effective_start_block),
            };
        }

        let id = self.insert(key, contract_idx, reg.registration_block, effective_start_block);
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
        key: Key,
        contract_idx: u32,
        registration_block: i64,
    ) -> Option<RejectedRow> {
        let contract_start_block = self.contract_start_blocks[contract_idx as usize];
        let effective_start_block =
            derive_effective_start_block(registration_block, contract_start_block);
        if let Some(id) = self.live_id_for(&key, contract_idx) {
            return Some(RejectedRow {
                address: address_string(self.ecosystem, &key),
                contract_name: self.contract_name(contract_idx).to_string(),
                kind: VERDICT_DUPLICATE.to_string(),
                effective_start_block,
                existing_effective_start_block: Some(self.entry(id).effective_start_block),
            });
        }
        self.insert(key, contract_idx, registration_block, effective_start_block);
        None
    }

    /// Appends a live entry and links it at the head of its key's chain.
    fn insert(
        &mut self,
        key: Key,
        contract_idx: u32,
        registration_block: i64,
        effective_start_block: i64,
    ) -> u64 {
        let id = self.entries.len() as u64;
        let next_by_key = self.id_by_key.insert(key.clone(), id);
        self.entries.push(Entry {
            key,
            contract_idx,
            registration_block,
            effective_start_block,
            dead: false,
            next_by_key,
        });
        self.live_count_by_contract[contract_idx as usize] += 1;
        id
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
    /// First owning contract of each address in the set, plus the rare tail for
    /// an address several contracts index — so the common single-owner case
    /// costs no allocation per address.
    owner_by_key: HashMap<Key, u32>,
    extra_owners_by_key: HashMap<Key, Vec<u32>>,
    len: usize,
}

/// The contracts a set holds one address for, as routing reads them: at most a
/// handful, scanned rather than hashed.
#[derive(Clone, Copy, Default)]
pub struct Owners<'a> {
    first: Option<u32>,
    rest: &'a [u32],
}

impl Owners<'static> {
    /// A set holding the address for exactly one contract — the shape every
    /// single-owner routing test builds by hand.
    #[cfg(test)]
    pub(crate) fn single(contract_idx: u32) -> Self {
        Self {
            first: Some(contract_idx),
            rest: &[],
        }
    }
}

impl Owners<'_> {
    pub fn contains(&self, contract_idx: u32) -> bool {
        self.first == Some(contract_idx) || self.rest.contains(&contract_idx)
    }

    pub fn is_empty(&self) -> bool {
        self.first.is_none()
    }
}

impl SetCache {
    pub fn slice(&self, contract_name: &str) -> Option<&ContractSlice> {
        self.index_by_name
            .get(contract_name)
            .map(|&idx| &self.contracts[idx])
    }

    /// The contracts owning an address, by the raw bytes the source handed back
    /// (EVM/Fuel address bytes, an SVM `programId`'s base58 bytes). Empty means
    /// the address isn't in this partition — the log routes to wildcards only.
    pub fn owners_of(&self, key: &[u8]) -> Owners<'_> {
        Owners {
            first: self.owner_by_key.get(key).copied(),
            rest: self
                .extra_owners_by_key
                .get(key)
                .map_or(&[][..], |owners| owners.as_slice()),
        }
    }

    /// Whether this set holds the address for the given contract.
    pub fn owns(&self, key: &[u8], contract_idx: u32) -> bool {
        self.owners_of(key).contains(contract_idx)
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
        indexed && self.cache().owns(&key, contract_idx)
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
            let mut owner_by_key: HashMap<Key, u32> = HashMap::with_capacity(self.ids.len());
            let mut extra_owners_by_key: HashMap<Key, Vec<u32>> = HashMap::new();
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
                match owner_by_key.entry(entry.key.clone()) {
                    std::collections::hash_map::Entry::Vacant(vacant) => {
                        vacant.insert(entry.contract_idx);
                    }
                    std::collections::hash_map::Entry::Occupied(_) => {
                        extra_owners_by_key
                            .entry(entry.key.clone())
                            .or_default()
                            .push(entry.contract_idx);
                    }
                }
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
                extra_owners_by_key,
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
                .enumerate()
                .map(|(idx, (name, _))| AddressStoreContract {
                    id: idx as u32,
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
            .enumerate()
            .map(|(idx, (name, start_block))| AddressStoreContract {
                id: idx as u32,
                name: name.to_string(),
                start_block: *start_block,
                depends_on_addresses: true,
            })
            .collect()
    }

    /// A contract nothing on this chain fetches by address — either it has no
    /// events here, or they're all wildcard. Registered and persisted like any
    /// other, never fetched.
    fn address_independent_contract(id: u32, name: &str) -> AddressStoreContract {
        AddressStoreContract {
            id,
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
    fn duplicate_carries_the_existing_registration() {
        let store = store();
        let verdicts = store.register_seed(vec![
            reg(A, "C", 10),
            // Same address, same contract — duplicate, with what's already held.
            reg(A, "C", 20),
            // Same address, another contract — a registration of its own.
            reg(A, "D", 20),
            // And a duplicate of that one, resolved inside the same batch.
            reg(A, "D", 30),
        ]);
        assert_eq!(
            verdicts
                .iter()
                .map(|v| (v.kind.as_str(), v.existing_effective_start_block))
                .collect::<Vec<_>>(),
            vec![
                ("added", None),
                ("duplicate", Some(100)),
                ("added", None),
                ("duplicate", Some(20)),
            ]
        );
    }

    #[test]
    fn an_address_is_registered_per_contract() {
        // "D" stands in for a contract nothing on this chain fetches by
        // address: the store treats it like any other, and the fetch state
        // decides nothing is queried for it.
        let store = store();
        let verdicts = store.register_seed(vec![reg(A, "D", 10), reg(A, "C", 20), reg(A, "D", 30)]);
        assert_eq!(
            (
                kinds(&verdicts),
                // One registration per (address, contract), so the shared
                // address counts once for each.
                store.size(),
                store.contract_addresses("C".to_string()),
                store.contract_addresses("D".to_string()),
                store.get_all(A.to_string()).len(),
            ),
            (
                vec!["added", "added", "duplicate"],
                2,
                vec![A.to_string()],
                vec![A.to_string()],
                2,
            )
        );
    }

    #[test]
    fn rolling_back_one_owner_leaves_the_others_indexing() {
        let store = store();
        store.register_seed(vec![reg(A, "C", 100)]);
        store.register_batch(vec![reg(A, "D", 500)]).unwrap();
        let removed = store.rollback(300);
        assert_eq!(
            (
                removed,
                // C registered A at 100, so it survives...
                store.is_indexed_at(A.to_string(), "C".to_string(), 600),
                // ...while D's registration at 500 is gone.
                store.is_indexed_at(A.to_string(), "D".to_string(), 600),
                store.contract_addresses("C".to_string()),
                store.contract_addresses("D".to_string()),
                // And the surviving registration is still reachable by key.
                store.get_all(A.to_string()).len(),
            ),
            (1, true, false, vec![A.to_string()], vec![], 1)
        );
    }

    #[test]
    fn a_shared_address_sorts_by_contract_within_its_start_block() {
        // The sort key must stay total over live entries: two registrations of
        // one address at one start block differ only by contract.
        let store = AddressStore::new_evm(false, contracts(&[("C", None), ("D", None)]));
        store.register_seed(vec![reg(A, "D", 10), reg(A, "C", 10)]);
        let merged = store
            .make_set("C".to_string(), None)
            .merge(&store.make_set("D".to_string(), None));
        assert_eq!(
            (
                merged.size(),
                merged
                    .entries()
                    .into_iter()
                    .map(|e| e.contract_name)
                    .collect::<Vec<_>>(),
                // Merging the same set twice still collapses: equal sort keys
                // are the same id, never two registrations.
                merged.merge(&merged).size(),
            ),
            (2, vec!["C".to_string(), "D".to_string()], 2)
        );
    }

    #[test]
    fn make_set_of_takes_every_owner_of_an_address() {
        let store = store();
        store.register_seed(vec![reg(A, "C", 10), reg(A, "D", 10), reg(B, "C", 10)]);
        let set = store.make_set_of(vec![A.to_string()]);
        assert_eq!(
            (
                set.size(),
                set.count_for("C".to_string()),
                set.count_for("D".to_string()),
            ),
            (2, 1, 1)
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
                address_independent_contract(1, "D"),
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
        let ecosystem = Ecosystem::Evm {
            should_checksum: false,
        };
        store
            .drain_for_write(to_block, checkpoints.to_vec())
            .unwrap()
            .into_iter()
            .map(|e| {
                (
                    address_string(ecosystem, &e.address),
                    e.registration_block,
                    e.checkpoint_idx,
                )
            })
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
    fn seeded_rows_carry_their_own_encoding() {
        let store = store();
        let packed = pack_addresses(
            "evm".to_string(),
            vec![A.to_string(), A.to_string(), B.to_string()],
        )
        .unwrap();
        let rejected = store
            .seed_rows(packed.bytes, packed.lengths, vec![0, 1, 0], vec![-1, 40, 50])
            .unwrap();
        assert_eq!(
            (
                rejected.len(),
                store.contract_addresses("C".to_string()),
                store.contract_addresses("D".to_string()),
                store.contract_count("C".to_string()),
                // Nothing seeded is ever written back.
                store.pending_count(),
            ),
            (
                0,
                vec![A.to_string(), B.to_string()],
                vec![A.to_string()],
                2,
                0
            )
        );
    }

    #[test]
    fn a_seeded_row_repeating_a_registration_is_rejected_not_registered() {
        let store = store();
        let packed = pack_addresses("evm".to_string(), vec![A.to_string(), A.to_string()]).unwrap();
        let rejected = store
            .seed_rows(packed.bytes, packed.lengths, vec![0, 0], vec![-1, 200])
            .unwrap();
        assert_eq!(
            (
                rejected
                    .iter()
                    .map(|r| (r.address.as_str(), r.contract_name.as_str(), r.kind.as_str()))
                    .collect::<Vec<_>>(),
                store.size(),
            ),
            (vec![(A, "C", "duplicate")], 1)
        );
    }

    #[test]
    fn contract_names_get_canonical_ids_by_byte_order() {
        assert_eq!(
            canonical_contract_names(vec![
                "Pool".to_string(),
                "Factory".to_string(),
                "Pool".to_string(),
                "ERC20".to_string(),
            ]),
            vec![
                "ERC20".to_string(),
                "Factory".to_string(),
                "Pool".to_string()
            ]
        );
    }

    #[test]
    fn dynamic_contract_names_are_the_ones_with_a_registration_block() {
        let store = store();
        store.register_seed(vec![reg(A, "C", -1), reg(B, "D", 10)]);
        assert_eq!(store.dynamic_contract_names(), vec!["D".to_string()]);
    }

    #[test]
    fn rolled_back_address_can_be_registered_again() {
        let store = store();
        store.register_seed(vec![reg(A, "C", 500)]);
        store.rollback(300);
        let verdicts = store.register_seed(vec![reg(A, "C", 400)]);
        assert_eq!(
            (kinds(&verdicts), store.contract_addresses("C".to_string())),
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
                // Registered for C only, so D's gate stays shut for it.
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
        // A is shared by both contracts; C (the address) only by "D".
        store.register_seed(vec![reg(A, "C", 100), reg(A, "D", 100), reg(C, "D", 200)]);
        let set = store
            .make_set("C".to_string(), None)
            .merge(&store.make_set("D".to_string(), None));
        let cache = set.cache();
        let key_of = |address| {
            address_key(
                Ecosystem::Evm {
                    should_checksum: false,
                },
                address,
            )
            .unwrap()
        };
        let a_key = key_of(A);
        assert_eq!(
            (
                cache.owns(&a_key, 0),
                cache.owns(&a_key, 1),
                cache.owns(&key_of(C), 0),
                cache.owns(&key_of(B), 0),
                cache.owners_of(&key_of(B)).is_empty(),
                cache.slice("C").map(|s| s.topics.clone()),
                cache.slice("Missing").is_none(),
                cache.len(),
            ),
            (
                true,
                true,
                false,
                false,
                true,
                Some(vec![
                    "0x00000000000000000000000000000000000000000000000000000000000000aa"
                        .to_string()
                ]),
                true,
                3,
            )
        );
    }

    #[test]
    fn contains_at_is_a_membership_test_over_every_owner() {
        let store = store();
        store.register_seed(vec![reg(A, "C", 100), reg(A, "D", 100)]);
        let set = store.make_set("C".to_string(), None);
        assert_eq!(
            (
                set.contains_at(A.to_string(), "C".to_string(), 100),
                // Registered for D chain-wide, but this set holds only C's
                // registration of it.
                set.contains_at(A.to_string(), "D".to_string(), 100),
                store
                    .make_set_of(vec![A.to_string()])
                    .contains_at(A.to_string(), "D".to_string(), 100),
            ),
            (true, false, true)
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
