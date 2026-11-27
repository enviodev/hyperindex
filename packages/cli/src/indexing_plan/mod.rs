//! The indexing plan: per chain, what is needed, what is covered, and what
//! work is out, with the work computed from those tables on every tick.
//! Nothing is merged, split, retired or renumbered. It does no IO and reads no
//! clock: the loop takes work from it and hands back what came of it.

mod budget;
mod chain;
mod coverage;
mod pipeline;
#[cfg(test)]
mod tests;

use napi_derive::napi;

use crate::address_store::client_filtered_contracts::ClientFilteredContracts;
use crate::address_store::{AddressRegistration, AddressSet, AddressStore, Id, RolledBackAddress};
use crate::chain_buffer::merge::HashMismatch;
use crate::chain_buffer::page::Page;
use crate::chain_buffer::ChainBuffer;
use budget::ChainInput;
use chain::{
    Addresses, BlockRegistration, ChainConfig, ChainPlan, EventRegistration, Notice, What,
};
use pipeline::Planned;

/// The RPC client's learned block interval of the one stream a chain runs at
/// the head, apart from every need's own.
pub(crate) const HEAD_STREAM_INTERVAL_KEY: u32 = u32::MAX;

/// How close to the head every need of a chain has to be for it to fetch each
/// new block in one request. A source this far behind the others is held.
#[cfg_attr(test, allow(dead_code))]
#[napi]
pub fn head_distance() -> u32 {
    chain::HEAD_DISTANCE as u32
}

#[napi(object)]
pub struct PlanEventRegistration {
    pub index: u32,
    pub contract_name: String,
    pub depends_on_addresses: bool,
    pub start_block: Option<i64>,
}

#[napi(object)]
pub struct PlanBlockRegistration {
    pub index: u32,
    pub start_block: Option<i64>,
}

#[napi(object)]
pub struct PlanChainConfig {
    pub chain_id: i64,
    pub start_block: i64,
    pub end_block: Option<i64>,
    pub block_lag: i64,
    pub block_throttle: i64,
    pub known_height: i64,
    pub progress_block_number: i64,
    pub max_reorg_depth: i64,
    pub should_rollback_on_reorg: bool,
    pub max_addresses_per_group: u32,
    pub address_free_threshold: Option<u32>,
    /// Block handlers that read no block field: the buffer generates their
    /// items, so they are never fetched.
    pub has_generated_block_handlers: bool,
    pub ecosystem: String,
    pub on_event_registrations: Vec<PlanEventRegistration>,
    /// Block handlers that read block fields.
    pub fetched_block_registrations: Vec<PlanBlockRegistration>,
    pub on_transaction_registrations: Vec<PlanBlockRegistration>,
    pub is_resumed: bool,
}

#[napi(discriminant = "kind")]
pub enum PlanNotice {
    SwitchedToAddressFree {
        contract_name: String,
        address_count: u32,
        threshold: u32,
    },
    WentAddressFreeNearHead {
        contract_names: Vec<String>,
    },
    SkippedInvalidAddress {
        contract_name: String,
        contract_address: String,
    },
}

fn to_napi_notices(notices: Vec<Notice>) -> Vec<PlanNotice> {
    notices
        .into_iter()
        .map(|notice| match notice {
            Notice::SwitchedToAddressFree {
                contract_name,
                address_count,
                threshold,
            } => PlanNotice::SwitchedToAddressFree {
                contract_name,
                address_count,
                threshold,
            },
            Notice::WentAddressFreeNearHead { contract_names } => {
                PlanNotice::WentAddressFreeNearHead { contract_names }
            }
            Notice::SkippedInvalidAddress {
                contract_name,
                address,
            } => PlanNotice::SkippedInvalidAddress {
                contract_name,
                contract_address: address,
            },
        })
        .collect()
}

/// What the plan reads of a chain on each tick from the loop.
#[napi(object)]
pub struct PlanChainTick {
    pub chain_id: i64,
    pub processing_block_number: i64,
    pub processed_density: Option<f64>,
}

#[napi(object, object_from_js = false)]
pub struct ChainFetchWork {
    pub chain_id: i64,
    /// Nothing to fetch until the chain learns a newer head.
    pub wait_for_new_block: bool,
    pub requests: Vec<FetchRequest>,
}

#[napi(object)]
pub struct FetchCompletion {
    /// The block whose received hash differs from the stored one. With
    /// rollback on, nothing of the page merged and nothing moved.
    pub mismatch: Option<HashMismatch>,
    pub rows_kept: u32,
    pub registering_block_count: u32,
    pub notices: Vec<PlanNotice>,
}

/// What a request selects at one attempt's end block: a registration whose
/// own start block lies past it can't produce an item there, so it isn't
/// asked for.
pub(crate) struct RequestSelection {
    pub on_event_registration_indexes: Vec<i64>,
    pub on_block_registration_indexes: Vec<i64>,
    pub on_transaction_registration_indexes: Vec<i64>,
    pub client_filtered: ClientFilteredContracts,
}

#[napi(object)]
pub struct FetchRequestSelection {
    pub on_event_registration_indexes: Vec<u32>,
    pub on_block_registration_indexes: Vec<u32>,
    pub on_transaction_registration_indexes: Vec<u32>,
    /// Contracts whose address-dependent events are fetched without an
    /// address filter.
    pub address_free_contracts: Vec<String>,
}

/// A request handed out to run against a source, as it was when taken.
#[napi]
pub struct FetchRequest {
    chain_id: i64,
    slot: u32,
    generation: u32,
    from_block: i64,
    to_block: Option<i64>,
    items_estimate: u32,
    interval_key: u32,
    /// The chain's one forward stream at the head.
    head: bool,
    /// (index, start block), ascending by index.
    event_registrations: Vec<(u32, Option<i64>)>,
    block_registrations: Vec<u32>,
    transaction_registrations: Vec<u32>,
    address_free_contracts: Vec<String>,
    address_set: AddressSet,
}

#[napi]
impl FetchRequest {
    #[napi(getter)]
    pub fn from_block(&self) -> i64 {
        self.from_block
    }

    /// Inclusive. None asks for everything the source has from `from_block`.
    #[napi(getter)]
    pub fn to_block(&self) -> Option<i64> {
        self.to_block
    }

    #[napi(getter)]
    pub fn items_estimate(&self) -> u32 {
        self.items_estimate
    }

    /// The addresses it asks for, in set order.
    #[napi(getter)]
    pub fn addresses(&self) -> Vec<String> {
        self.address_set.addresses()
    }

    #[napi(js_name = "selection")]
    pub fn selection_view(&self, to_block: Option<i64>) -> FetchRequestSelection {
        let selection = self.selection(to_block);
        FetchRequestSelection {
            on_event_registration_indexes: selection
                .on_event_registration_indexes
                .iter()
                .map(|&index| index as u32)
                .collect(),
            on_block_registration_indexes: self.block_registrations.clone(),
            on_transaction_registration_indexes: self.transaction_registrations.clone(),
            address_free_contracts: self.address_free_contracts.clone(),
        }
    }

    /// Whether it asks for the address under the contract, and the address
    /// has started at the block: the gate a source applies to what it brings
    /// back.
    #[napi]
    pub fn contains_address_at(
        &self,
        address: String,
        contract_name: String,
        block_number: i64,
    ) -> bool {
        self.address_set
            .contains_at(address, contract_name, block_number)
    }
}

/// A request built outside a plan, for a source driven on its own.
#[napi(object)]
pub struct StandaloneFetchRequest {
    pub from_block: i64,
    pub to_block: Option<i64>,
    pub on_event_registration_indexes: Vec<u32>,
    pub on_block_registration_indexes: Vec<u32>,
    pub on_transaction_registration_indexes: Vec<u32>,
    pub address_free_contracts: Vec<String>,
    /// Only these of the contracts' addresses, when given.
    pub addresses: Option<Vec<String>>,
}

#[napi]
impl FetchRequest {
    /// It belongs to no plan, so no plan completes it.
    #[napi(factory)]
    pub fn standalone(
        request: StandaloneFetchRequest,
        address_store: &AddressStore,
        contract_names: Vec<String>,
    ) -> Self {
        Self {
            chain_id: i64::MIN,
            slot: u32::MAX,
            generation: 0,
            from_block: request.from_block,
            to_block: request.to_block,
            items_estimate: 0,
            interval_key: HEAD_STREAM_INTERVAL_KEY,
            head: false,
            event_registrations: request
                .on_event_registration_indexes
                .into_iter()
                .map(|index| (index, None))
                .collect(),
            block_registrations: request.on_block_registration_indexes,
            transaction_registrations: request.on_transaction_registration_indexes,
            address_free_contracts: request.address_free_contracts,
            address_set: address_store
                .set_of_addresses(&contract_names, request.addresses.as_deref()),
        }
    }
}

impl FetchRequest {
    pub(crate) fn selection(&self, to_block: Option<i64>) -> RequestSelection {
        let all: Vec<i64> = self
            .event_registrations
            .iter()
            .map(|&(index, _)| i64::from(index))
            .collect();
        let on_event_registration_indexes = match to_block {
            None => all,
            Some(to_block) => {
                let in_range: Vec<i64> = self
                    .event_registrations
                    .iter()
                    .filter(|(_, start_block)| start_block.is_none_or(|start| start <= to_block))
                    .map(|&(index, _)| i64::from(index))
                    .collect();
                // Narrowed to nothing, a selection has no log filter, which a
                // source reads as every log: asked whole, matching drops what
                // hasn't started.
                if in_range.is_empty() {
                    all
                } else {
                    in_range
                }
            }
        };
        RequestSelection {
            on_event_registration_indexes,
            on_block_registration_indexes: self
                .block_registrations
                .iter()
                .map(|&i| i64::from(i))
                .collect(),
            on_transaction_registration_indexes: self
                .transaction_registrations
                .iter()
                .map(|&i| i64::from(i))
                .collect(),
            client_filtered: ClientFilteredContracts::from_vec(self.address_free_contracts.clone()),
        }
    }

    pub(crate) fn address_set(&self) -> &AddressSet {
        &self.address_set
    }

    pub(crate) fn interval_key(&self) -> u32 {
        self.interval_key
    }

    pub(crate) fn is_head(&self) -> bool {
        self.head
    }

    pub(crate) fn requested_from_block(&self) -> i64 {
        self.from_block
    }

    /// Only block fields: the source picks the blocks to read within its range
    /// and answers for the gaps between them, which can't run past the head.
    pub(crate) fn reads_blocks_alone(&self) -> bool {
        self.event_registrations.is_empty() && self.transaction_registrations.is_empty()
    }
}

#[napi]
pub struct IndexingPlan {
    chains: Vec<ChainPlan>,
}

impl IndexingPlan {
    fn chain_mut(&mut self, chain_id: i64) -> napi::Result<&mut ChainPlan> {
        self.chains
            .iter_mut()
            .find(|chain| chain.config.chain_id == chain_id)
            .ok_or_else(|| {
                napi::Error::from_reason(format!("Chain {chain_id} is not in the indexing plan."))
            })
    }

    fn chain(&self, chain_id: i64) -> napi::Result<&ChainPlan> {
        self.chains
            .iter()
            .find(|chain| chain.config.chain_id == chain_id)
            .ok_or_else(|| {
                napi::Error::from_reason(format!("Chain {chain_id} is not in the indexing plan."))
            })
    }
}

fn request_handle(chain: &ChainPlan, slot: u32, generation: u32) -> FetchRequest {
    let request = chain.requests.slots[slot as usize]
        .as_ref()
        .expect("a request just started is in its slot");
    let store = chain.store.read().unwrap();
    let mut event_registrations: Vec<u32> = Vec::new();
    let mut ids: Vec<Id> = Vec::new();
    let mut address_free_contracts: Vec<String> = Vec::new();
    let mut block_registrations = Vec::new();
    let mut transaction_registrations = Vec::new();
    for &need in &request.needs {
        match &chain.needs.what[need as usize] {
            What::Logs {
                registrations,
                addresses,
            } => {
                event_registrations.extend_from_slice(registrations);
                match addresses {
                    Addresses::Group(group) => {
                        ids.extend_from_slice(&chain.groups.ids[*group as usize])
                    }
                    Addresses::List(list) => ids.extend_from_slice(list),
                    Addresses::Free => {
                        for &index in registrations {
                            let reg = &chain.config.events[index as usize];
                            let name = &store.contract_names()[reg.contract as usize];
                            if reg.depends_on_addresses && !address_free_contracts.contains(name) {
                                address_free_contracts.push(name.clone());
                            }
                        }
                    }
                }
            }
            What::Blocks => {
                block_registrations = chain.config.blocks.iter().map(|reg| reg.index).collect()
            }
            What::Transactions => {
                transaction_registrations = chain
                    .config
                    .transactions
                    .iter()
                    .map(|reg| reg.index)
                    .collect()
            }
        }
    }
    event_registrations.sort_unstable();
    event_registrations.dedup();
    ids.sort_unstable();
    ids.dedup();
    // Read address-free already, a contract's addresses would only ask the
    // source again for logs it returns.
    ids.retain(|&id| {
        !address_free_contracts.contains(&store.contract_names()[store.contract_of(id) as usize])
    });
    store.sort_in_set_order(&mut ids);
    address_free_contracts.sort_unstable();
    drop(store);
    FetchRequest {
        chain_id: chain.config.chain_id,
        slot,
        generation,
        from_block: request.from_block,
        to_block: request.to_block,
        items_estimate: request.items_estimate,
        interval_key: if request.head {
            HEAD_STREAM_INTERVAL_KEY
        } else {
            request.needs[0]
        },
        head: request.head,
        event_registrations: event_registrations
            .into_iter()
            .map(|index| (index, chain.config.events[index as usize].start_block))
            .collect(),
        block_registrations,
        transaction_registrations,
        address_free_contracts,
        address_set: AddressSet::new(chain.store.clone(), ids),
    }
}

#[napi]
impl IndexingPlan {
    #[napi(factory)]
    pub fn make() -> Self {
        Self { chains: Vec::new() }
    }

    /// The chain's starting needs, from the addresses its store holds.
    #[napi]
    pub fn add_chain(
        &mut self,
        config: PlanChainConfig,
        address_store: &AddressStore,
        chain_buffer: &ChainBuffer,
    ) -> napi::Result<Vec<PlanNotice>> {
        let store = address_store.handle();
        let (events, contract_end_blocks) = {
            let store = store.read().unwrap();
            let mut events = Vec::with_capacity(config.on_event_registrations.len());
            for (position, reg) in config.on_event_registrations.iter().enumerate() {
                if reg.index as usize != position {
                    return Err(napi::Error::from_reason(format!(
                        "Event registration {} is at position {position}.",
                        reg.index
                    )));
                }
                let contract = store.contract_idx(&reg.contract_name).ok_or_else(|| {
                    napi::Error::from_reason(format!(
                        "Contract \"{}\" is not in the chain's address store.",
                        reg.contract_name
                    ))
                })?;
                events.push(EventRegistration {
                    index: reg.index,
                    contract,
                    depends_on_addresses: reg.depends_on_addresses,
                    start_block: reg.start_block,
                });
            }
            let contract_end_blocks = (0..store.contract_names().len() as u32)
                .map(|contract| store.contract_end_block(contract))
                .collect();
            (events, contract_end_blocks)
        };
        let blocks = |regs: &[PlanBlockRegistration]| {
            regs.iter()
                .map(|reg| BlockRegistration {
                    index: reg.index,
                    start_block: reg.start_block,
                })
                .collect()
        };
        let chain_config = ChainConfig {
            chain_id: config.chain_id,
            start_block: config.start_block,
            end_block: config.end_block,
            block_lag: config.block_lag,
            block_throttle: config.block_throttle,
            known_height: config.known_height,
            progress_block_number: config.progress_block_number,
            max_reorg_depth: config.max_reorg_depth,
            should_rollback_on_reorg: config.should_rollback_on_reorg,
            max_group_size: config.max_addresses_per_group as usize,
            address_free_threshold: config.address_free_threshold,
            has_generated_block_handlers: config.has_generated_block_handlers,
            blocks_apart: config.ecosystem == "svm",
            events,
            blocks: blocks(&config.fetched_block_registrations),
            transactions: blocks(&config.on_transaction_registrations),
            contract_end_blocks,
            is_resumed: config.is_resumed,
        };
        let (chain, notices) = ChainPlan::new(chain_config, store, chain_buffer.clone())
            .map_err(napi::Error::from_reason)?;
        self.chains
            .retain(|existing| existing.config.chain_id != config.chain_id);
        self.chains.push(chain);
        Ok(to_napi_notices(notices))
    }

    #[napi]
    pub fn set_known_height(
        &mut self,
        chain_id: i64,
        known_height: i64,
    ) -> napi::Result<Vec<PlanNotice>> {
        Ok(to_napi_notices(
            self.chain_mut(chain_id)?.set_known_height(known_height),
        ))
    }

    #[napi]
    pub fn set_block_lag(&mut self, chain_id: i64, block_lag: i64) -> napi::Result<()> {
        self.chain_mut(chain_id)?.block_lag = block_lag;
        Ok(())
    }

    #[napi]
    pub fn set_end_block(&mut self, chain_id: i64, end_block: Option<i64>) -> napi::Result<()> {
        self.chain_mut(chain_id)?.end_block = end_block;
        Ok(())
    }

    /// Every chain's work this tick, drawn from one pool of about
    /// `target_buffer_size` ready items: the requests to start, and the chains
    /// that wait for a new block instead. A chain with neither is left out.
    #[napi]
    pub fn take_fetch_requests_to_start(
        &mut self,
        ticks: Vec<PlanChainTick>,
        is_realtime: bool,
        target_buffer_size: u32,
    ) -> napi::Result<Vec<ChainFetchWork>> {
        let mut chains: Vec<&mut ChainPlan> = Vec::with_capacity(ticks.len());
        let mut inputs = Vec::with_capacity(ticks.len());
        let mut remaining: Vec<&mut ChainPlan> = self.chains.iter_mut().collect();
        for tick in &ticks {
            let position = remaining
                .iter()
                .position(|chain| chain.config.chain_id == tick.chain_id)
                .ok_or_else(|| {
                    napi::Error::from_reason(format!(
                        "Chain {} is not in the indexing plan.",
                        tick.chain_id
                    ))
                })?;
            chains.push(remaining.swap_remove(position));
            inputs.push(ChainInput {
                processing_block: tick.processing_block_number,
                processed_density: tick.processed_density,
            });
        }
        let planned = budget::take_requests(
            &mut chains,
            &inputs,
            f64::from(target_buffer_size),
            is_realtime,
        );
        Ok(chains
            .iter()
            .zip(planned)
            .filter_map(|(chain, planned)| match planned {
                Planned::NothingToDo => None,
                Planned::WaitForNewBlock => Some(ChainFetchWork {
                    chain_id: chain.config.chain_id,
                    wait_for_new_block: true,
                    requests: Vec::new(),
                }),
                Planned::Start(started) => Some(ChainFetchWork {
                    chain_id: chain.config.chain_id,
                    wait_for_new_block: false,
                    requests: started
                        .into_iter()
                        .map(|(slot, generation)| request_handle(chain, slot, generation))
                        .collect(),
                }),
            })
            .collect())
    }

    /// Merges the page and moves coverage to the block the source reached, in
    /// one step. None for a request a rollback has dropped.
    #[napi]
    pub fn complete_fetch_request(
        &mut self,
        request: &FetchRequest,
        page: &Page,
        latest_fetched_block_number: i64,
        source_index: u32,
        known_height: i64,
    ) -> napi::Result<Option<FetchCompletion>> {
        let chain = self.chain_mut(request.chain_id)?;
        let (completion, notices) = chain.complete(
            request.slot,
            request.generation,
            page,
            latest_fetched_block_number,
            source_index as usize,
            known_height,
        );
        Ok(completion.map(|completion| FetchCompletion {
            mismatch: completion.mismatch,
            rows_kept: completion.rows_kept,
            registering_block_count: completion.registering_block_count,
            notices: to_napi_notices(notices),
        }))
    }

    /// The request's blocks are missing again, for a later tick to ask for.
    #[napi]
    pub fn abandon_fetch_request(&mut self, request: &FetchRequest) -> napi::Result<()> {
        self.chain_mut(request.chain_id)?
            .abandon(request.slot, request.generation);
        Ok(())
    }

    /// Every request of the chain still out, asked against a state a reorg
    /// is about to roll back.
    #[napi]
    pub fn abandon_fetch_requests_in_flight(&mut self, chain_id: i64) -> napi::Result<()> {
        self.chain_mut(chain_id)?.abandon_all();
        Ok(())
    }

    /// Returns the registrations the rollback took out of the store, for
    /// storage to delete.
    #[napi]
    pub fn rollback_to_block(
        &mut self,
        chain_id: i64,
        block_number: i64,
    ) -> napi::Result<Vec<RolledBackAddress>> {
        Ok(self.chain_mut(chain_id)?.rollback(block_number))
    }

    #[napi]
    pub fn get_ready_through_block(&self, chain_id: i64) -> napi::Result<i64> {
        Ok(self.chain(chain_id)?.ready_through_block())
    }

    /// Request streams: each unfinished need during backfill; at the head
    /// one, plus the needs still catching up.
    #[napi]
    pub fn get_request_stream_count(&self, chain_id: i64) -> napi::Result<u32> {
        Ok(self.chain(chain_id)?.streams().len() as u32)
    }

    #[napi]
    pub fn has_contract_register_backlog(&self, chain_id: i64) -> napi::Result<bool> {
        Ok(self.chain(chain_id)?.has_backlog())
    }

    /// The backlog's blocks, for one contractRegister run.
    #[napi]
    pub fn take_contract_register_blocks_to_run(
        &mut self,
        chain_id: i64,
    ) -> napi::Result<Vec<i64>> {
        Ok(self.chain_mut(chain_id)?.take_contract_register_blocks())
    }

    /// Registers what the run added and takes the blocks it covered off the
    /// backlog. A run whose result is dropped completes with neither.
    #[napi]
    pub fn complete_contract_register_run(
        &mut self,
        chain_id: i64,
        block_numbers: Vec<i64>,
        registrations: Vec<AddressRegistration>,
    ) -> napi::Result<Vec<PlanNotice>> {
        let chain = self.chain_mut(chain_id)?;
        let notices = chain
            .complete_contract_register_run(&block_numbers, registrations)
            .map_err(napi::Error::from_reason)?;
        Ok(to_napi_notices(notices))
    }
}
