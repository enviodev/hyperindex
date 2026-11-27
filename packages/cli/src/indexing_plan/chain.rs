use std::sync::{Arc, RwLock};

use super::coverage::{intersection, union, Coverage, Ranges};
use crate::address_store::{
    AddressRegistration, AddressStore, Id, StoreInner, VERDICT_ADDED, VERDICT_INVALID,
};
use crate::chain_buffer::merge::HashMismatch;
use crate::chain_buffer::page::Page;
use crate::chain_buffer::ChainBuffer;

/// Config addresses whose start blocks lie within this many blocks of each
/// other share a group. A guess that is not critical either way: off, it only
/// queries some range more than once.
pub(crate) const TOO_FAR_BLOCK_RANGE: i64 = 20_000;

/// Counted in blocks whatever the chain's block time: the chain still fetches
/// block by block near the head, and an address-free query must never reach
/// back into a range a need is still backfilling.
pub(crate) const HEAD_DISTANCE: i64 = 200;

pub(crate) struct EventRegistration {
    pub index: u32,
    pub contract: u32,
    pub depends_on_addresses: bool,
    pub start_block: Option<i64>,
}

pub(crate) struct BlockRegistration {
    pub index: u32,
    pub start_block: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Addresses {
    /// The addresses of a group, as they are when a request is taken.
    Group(u32),
    /// A fixed list, for what a set of addresses owes below the block they
    /// joined a group at.
    List(Vec<Id>),
    /// No address filter: the store gates what comes back.
    Free,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum What {
    /// Logs of these event registrations.
    Logs {
        registrations: Vec<u32>,
        addresses: Addresses,
    },
    /// The fields of the blocks the chain's fetched block handlers run on.
    Blocks,
    /// The chain's transaction handlers' transactions.
    Transactions,
}

/// The last two block ranges a source showed it can return in one response.
#[derive(Clone, Copy, Default, Debug)]
pub(crate) struct Capacity {
    pub last: i64,
    pub previous: i64,
    /// The block the response that last moved it reached, so a response
    /// arriving out of order can't undo a later one.
    pub updated_at_block: i64,
}

impl Capacity {
    /// Trusted only once two ranges are known.
    pub fn chunk_range(&self) -> Option<i64> {
        (self.last > 0 && self.previous > 0).then(|| self.last.min(self.previous))
    }
}

#[derive(Clone, Default, Debug)]
pub(crate) struct Learned {
    /// Smoothed items per block. None until the first response, which tells a
    /// new need apart from one that measured zero.
    pub density: Option<f64>,
    /// By source index.
    pub capacity: Vec<Capacity>,
}

impl Learned {
    pub fn capacity_of(&self, source: usize) -> Capacity {
        self.capacity.get(source).copied().unwrap_or_default()
    }
}

#[derive(Default)]
pub(crate) struct Needs {
    pub what: Vec<What>,
    /// The block below which the need holds nothing, whatever progress says:
    /// the one before its addresses or registrations can first match.
    pub floor: Vec<i64>,
    pub to_block: Vec<Option<i64>>,
    pub coverage: Vec<Coverage>,
    pub learned: Vec<Learned>,
    /// For a list need, the need its addresses are part of from the block after
    /// its end.
    pub joins: Vec<Option<u32>>,
    pub live: Vec<bool>,
    pub ever_requested: Vec<bool>,
}

impl Needs {
    pub fn len(&self) -> u32 {
        self.what.len() as u32
    }

    pub fn is_finished(&self, need: u32) -> bool {
        let n = need as usize;
        !self.live[n] || self.to_block[n].is_some_and(|to| self.coverage[n].covered_through >= to)
    }

    pub fn is_list(&self, need: u32) -> bool {
        matches!(
            self.what[need as usize],
            What::Logs {
                addresses: Addresses::List(_),
                ..
            }
        )
    }
}

#[derive(Default)]
pub(crate) struct Groups {
    /// In set order.
    pub ids: Vec<Vec<Id>>,
    /// None for config addresses of several contracts.
    pub contract: Vec<Option<u32>>,
    pub sealed: Vec<bool>,
    pub need: Vec<u32>,
}

#[derive(Clone, Debug)]
pub(crate) struct Request {
    pub needs: Vec<u32>,
    pub from_block: i64,
    pub to_block: Option<i64>,
    pub items_estimate: u32,
    /// A chunk of a pipeline. Anything else, a probe above all, holds its
    /// stream's forward work until it lands, whatever its end.
    pub chunk: bool,
    /// The chain's one forward stream at the head.
    pub head: bool,
}

#[derive(Default)]
pub(crate) struct Requests {
    pub slots: Vec<Option<Request>>,
    pub generations: Vec<u32>,
}

impl Requests {
    pub fn in_flight(&self) -> impl Iterator<Item = &Request> {
        self.slots.iter().flatten()
    }

    pub fn insert(&mut self, request: Request) -> (u32, u32) {
        let slot = match self.slots.iter().position(Option::is_none) {
            Some(slot) => slot,
            None => {
                self.slots.push(None);
                self.generations.push(0);
                self.slots.len() - 1
            }
        };
        self.slots[slot] = Some(request);
        (slot as u32, self.generations[slot])
    }

    pub fn take(&mut self, slot: u32, generation: u32) -> Option<Request> {
        let slot = slot as usize;
        if self.generations.get(slot) != Some(&generation) {
            return None;
        }
        let request = self.slots[slot].take();
        if request.is_some() {
            self.generations[slot] = self.generations[slot].wrapping_add(1);
        }
        request
    }

    pub fn drop_all(&mut self) {
        for slot in 0..self.slots.len() {
            if self.slots[slot].take().is_some() {
                self.generations[slot] = self.generations[slot].wrapping_add(1);
            }
        }
    }
}

struct PendingJoin {
    contract: u32,
    ids: Vec<Id>,
    /// The lowest effective start block among them, which holds the frontier.
    start_block: i64,
}

/// What the plan has to tell an operator. It decides nothing from these; the
/// chain that owns it logs them.
pub(crate) enum Notice {
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
        address: String,
    },
}

pub(crate) struct Completion {
    pub mismatch: Option<HashMismatch>,
    pub rows_kept: u32,
    pub registering_block_count: u32,
}

pub(crate) struct ChainConfig {
    pub chain_id: i64,
    pub start_block: i64,
    pub end_block: Option<i64>,
    pub block_lag: i64,
    pub block_throttle: i64,
    pub known_height: i64,
    pub progress_block_number: i64,
    pub max_reorg_depth: i64,
    pub should_rollback_on_reorg: bool,
    pub max_group_size: usize,
    pub address_free_threshold: Option<u32>,
    pub has_generated_block_handlers: bool,
    /// SVM can't count transactions in a query that selects instructions.
    pub blocks_apart: bool,
    pub events: Vec<EventRegistration>,
    pub blocks: Vec<BlockRegistration>,
    pub transactions: Vec<BlockRegistration>,
    /// By store contract index.
    pub contract_end_blocks: Vec<Option<i64>>,
    pub is_resumed: bool,
}

pub(crate) struct ChainPlan {
    pub config: ChainConfig,
    pub known_height: i64,
    pub end_block: Option<i64>,
    pub block_lag: i64,
    pub needs: Needs,
    pub groups: Groups,
    pub requests: Requests,
    /// By store contract index.
    pub dynamic: Vec<bool>,
    pub address_free: Vec<bool>,
    pub open_group: Vec<Option<u32>>,
    pub address_free_need: Vec<Option<u32>>,
    pending_joins: Vec<PendingJoin>,
    /// (registered, retired): an address registered again from an earlier
    /// block. The retired entry stays in its needs, which go on fetching the
    /// address from its block.
    replaced: Vec<(Id, Id)>,
    pub head_mode: bool,
    pub head_learned: Learned,
    /// The source that answered last, whose capacity sizes the next chunks.
    pub last_source: usize,
    /// Blocks holding an event a contractRegister runs on that hasn't run yet,
    /// ascending and unique.
    pub backlog: Vec<i64>,
    /// While a run is out, the backlog blocks responses brought registering
    /// events for since it started: they stay on the backlog even if the run
    /// covered them, since it didn't read the new events.
    run_readded: Option<Vec<i64>>,
    pub store: Arc<RwLock<StoreInner>>,
    pub buffer: ChainBuffer,
}

fn store_live_count(store: &Arc<RwLock<StoreInner>>, contract: u32) -> u32 {
    store.read().unwrap().live_count_of(contract)
}

/// The one before the earliest block any of the registrations can produce an
/// item at, or None when one of them is unrestricted.
fn selection_floor(start_blocks: impl IntoIterator<Item = Option<i64>>) -> Option<i64> {
    let mut earliest: Option<i64> = None;
    let mut any = false;
    for start_block in start_blocks {
        any = true;
        let start_block = start_block?;
        earliest = Some(earliest.map_or(start_block, |e| e.min(start_block)));
    }
    if any {
        earliest.map(|e| e - 1)
    } else {
        None
    }
}

impl ChainPlan {
    pub fn new(
        config: ChainConfig,
        store: Arc<RwLock<StoreInner>>,
        buffer: ChainBuffer,
    ) -> Result<(Self, Vec<Notice>), String> {
        let contract_count = store.read().unwrap().contract_names().len();
        let mut plan = Self {
            known_height: config.known_height,
            end_block: config.end_block,
            block_lag: config.block_lag,
            needs: Needs::default(),
            groups: Groups::default(),
            requests: Requests::default(),
            dynamic: vec![false; contract_count],
            address_free: vec![false; contract_count],
            open_group: vec![None; contract_count],
            address_free_need: vec![None; contract_count],
            pending_joins: Vec::new(),
            replaced: Vec::new(),
            head_mode: false,
            head_learned: Learned::default(),
            last_source: 0,
            backlog: Vec::new(),
            run_readded: None,
            store,
            buffer,
            config,
        };
        let notices = plan.lay_out()?;
        Ok((plan, notices))
    }

    fn add_need(
        &mut self,
        what: What,
        floor: i64,
        covered_through: i64,
        to_block: Option<i64>,
    ) -> u32 {
        let needs = &mut self.needs;
        needs.what.push(what);
        needs.floor.push(floor);
        needs.to_block.push(to_block);
        needs
            .coverage
            .push(Coverage::new(covered_through.max(floor)));
        needs.learned.push(Learned::default());
        needs.joins.push(None);
        needs.live.push(true);
        needs.ever_requested.push(false);
        needs.len() - 1
    }

    fn address_events_of(&self, contract: u32) -> Vec<u32> {
        self.config
            .events
            .iter()
            .filter(|reg| reg.contract == contract && reg.depends_on_addresses)
            .map(|reg| reg.index)
            .collect()
    }

    fn events_floor(&self, registrations: &[u32]) -> Option<i64> {
        selection_floor(
            registrations
                .iter()
                .map(|&index| self.config.events[index as usize].start_block),
        )
    }

    fn has_address_events(&self, contract: u32) -> bool {
        self.config
            .events
            .iter()
            .any(|reg| reg.contract == contract && reg.depends_on_addresses)
    }

    /// Rule 5: what a chain starts with.
    fn lay_out(&mut self) -> Result<Vec<Notice>, String> {
        let progress = self.config.progress_block_number;
        let mut notices = Vec::new();
        let store = self.store.clone();
        let store = store.read().unwrap();
        let contract_count = store.contract_names().len() as u32;

        let mut address_contracts = Vec::new();
        for contract in 0..contract_count {
            if !self.has_address_events(contract) {
                continue;
            }
            if (0..store.id_count()).any(|id| {
                store.is_live(id)
                    && store.contract_of(id) == contract
                    && store.registration_block_of(id) != -1
            }) {
                self.dynamic[contract as usize] = true;
            }
            if store.live_count_of(contract) > 0 {
                address_contracts.push(contract);
            }
        }

        // Switched before any group is built: a contract big enough to cross
        // the threshold would otherwise get hundreds of groups only to drop them.
        let mut address_free_floor: Option<i64> = None;
        let mut address_free_registrations: Vec<u32> = self
            .config
            .events
            .iter()
            .filter(|reg| !reg.depends_on_addresses)
            .map(|reg| reg.index)
            .collect();
        if let Some(threshold) = self.config.address_free_threshold {
            for &contract in &address_contracts {
                let address_count = store.live_count_of(contract);
                if address_count > threshold {
                    self.address_free[contract as usize] = true;
                    if !self.config.is_resumed {
                        notices.push(Notice::SwitchedToAddressFree {
                            contract_name: store.contract_names()[contract as usize].clone(),
                            address_count,
                            threshold,
                        });
                    }
                    address_free_registrations.extend(self.address_events_of(contract));
                    let start = store
                        .live_ids_of_contract(contract, 0)
                        .first()
                        .map_or(i64::MAX, |&id| store.effective_start_block_of(id));
                    let frontier = (start - 1).max(progress);
                    address_free_floor =
                        Some(address_free_floor.map_or(frontier, |floor| floor.min(frontier)));
                }
            }
        }

        if !address_free_registrations.is_empty() {
            address_free_registrations.sort_unstable();
            let floor = self
                .events_floor(&address_free_registrations)
                .unwrap_or(i64::MIN);
            let covered =
                address_free_floor.map_or(progress.max(floor), |f| f.min(progress.max(floor)));
            let need = self.add_need(
                What::Logs {
                    registrations: address_free_registrations.clone(),
                    addresses: Addresses::Free,
                },
                floor.min(covered),
                covered,
                None,
            );
            for reg in &self.config.events {
                if reg.depends_on_addresses && self.address_free[reg.contract as usize] {
                    self.address_free_need[reg.contract as usize] = Some(need);
                }
            }
        }
        if !self.config.blocks.is_empty() {
            let floor = selection_floor(self.config.blocks.iter().map(|reg| reg.start_block))
                .unwrap_or(i64::MIN);
            self.add_need(What::Blocks, floor, progress, None);
        }
        if !self.config.transactions.is_empty() {
            self.add_need(What::Transactions, i64::MIN, progress, None);
        }

        // Static contracts share groups when their end blocks agree; each
        // dynamic contract's addresses are laid out on their own, its latest
        // group open for the addresses it registers next.
        let mut static_sets: Vec<(Option<i64>, Vec<u32>)> = Vec::new();
        for &contract in &address_contracts {
            if self.address_free[contract as usize] {
                continue;
            }
            if self.dynamic[contract as usize] {
                self.lay_out_contracts(&store, &[contract], progress);
            } else {
                let end_block = self.config.contract_end_blocks[contract as usize];
                match static_sets.iter_mut().find(|(end, _)| *end == end_block) {
                    Some((_, contracts)) => contracts.push(contract),
                    None => static_sets.push((end_block, vec![contract])),
                }
            }
        }
        for (_, contracts) in static_sets {
            self.lay_out_contracts(&store, &contracts, progress);
        }
        drop(store);

        if self.needs.len() == 0 && !self.config.has_generated_block_handlers {
            let address_count: u32 = (0..contract_count)
                .map(|c| store_live_count(&self.store, c))
                .sum();
            return Err(format!(
                "Invalid configuration: Nothing to fetch on chain {}. addresses={address_count}, \
                 onEventRegistrations={}, normalRegistrations={}. Make sure that you provided at \
                 least one contract address to index, or have events with Wildcard mode enabled, \
                 or have onBlock or onTransaction handlers.",
                self.config.chain_id,
                self.config.events.len(),
                self.config
                    .events
                    .iter()
                    .filter(|reg| reg.depends_on_addresses)
                    .count(),
            ));
        }
        Ok(notices)
    }

    /// Phase 1 cuts each contract's addresses into runs of start blocks close
    /// enough to share a query, at most a group each; phase 2 walks them by
    /// start: a run too far below the next owes a list need up to where the
    /// next starts and joins it there.
    fn lay_out_contracts(&mut self, store: &StoreInner, contracts: &[u32], progress: i64) {
        let max = self.config.max_group_size.max(1);
        let mut runs: Vec<(i64, Vec<Id>)> = Vec::new();
        for &contract in contracts {
            let ids = store.live_ids_of_contract(contract, 0);
            let mut start = 0;
            while start < ids.len() {
                let first_block = store.effective_start_block_of(ids[start]);
                let mut end = start;
                while end < ids.len()
                    && store.effective_start_block_of(ids[end]) - first_block < TOO_FAR_BLOCK_RANGE
                {
                    end += 1;
                }
                let covered = (first_block - 1).max(progress);
                for chunk in ids[start..end].chunks(max) {
                    runs.push((covered, chunk.to_vec()));
                }
                start = end;
            }
        }
        runs.sort_by_key(|(covered, _)| *covered);

        // (covered_through, ids, ends at).
        let mut segments: Vec<(i64, Vec<Id>, Option<i64>)> = Vec::new();
        let mut runs = runs.into_iter();
        let Some((mut current_block, mut current_ids)) = runs.next() else {
            return;
        };
        for (next_block, next_ids) in runs {
            if current_ids.len() + next_ids.len() > max {
                segments.push((current_block, current_ids, None));
                (current_block, current_ids) = (next_block, next_ids);
            } else if current_block + TOO_FAR_BLOCK_RANGE < next_block {
                let ends_at = (current_block < next_block).then_some(next_block);
                let mut merged = next_ids;
                merged.extend_from_slice(&current_ids);
                segments.push((current_block, current_ids, ends_at));
                (current_block, current_ids) = (next_block, merged);
            } else {
                current_ids.extend(next_ids);
            }
        }
        segments.push((current_block, current_ids, None));

        let contract = (contracts.len() == 1).then(|| contracts[0]);
        let registrations: Vec<u32> = {
            let mut registrations: Vec<u32> = contracts
                .iter()
                .flat_map(|&c| self.address_events_of(c))
                .collect();
            registrations.sort_unstable();
            registrations
        };
        let events_floor = self.events_floor(&registrations).unwrap_or(i64::MIN);
        let end_block = contracts
            .first()
            .and_then(|&c| self.config.contract_end_blocks[c as usize]);
        let mut pending_lists: Vec<u32> = Vec::new();
        for (covered, mut ids, ends_at) in segments {
            let covered = covered.max(events_floor);
            store.sort_in_set_order(&mut ids);
            let floor = ids
                .first()
                .map_or(i64::MIN, |&id| store.effective_start_block_of(id) - 1)
                .max(events_floor);
            match ends_at {
                Some(ends_at) => {
                    let need = self.add_need(
                        What::Logs {
                            registrations: registrations.clone(),
                            addresses: Addresses::List(ids),
                        },
                        floor.min(covered),
                        covered,
                        Some(end_block.map_or(ends_at, |end| end.min(ends_at))),
                    );
                    pending_lists.push(need);
                }
                None => {
                    let group = self.groups.ids.len() as u32;
                    let need = self.add_need(
                        What::Logs {
                            registrations: registrations.clone(),
                            addresses: Addresses::Group(group),
                        },
                        floor.min(covered),
                        covered,
                        end_block,
                    );
                    for list in pending_lists.drain(..) {
                        self.needs.joins[list as usize] = Some(need);
                    }
                    let sealed = contract.is_none() || ids.len() >= max;
                    self.groups.ids.push(ids);
                    self.groups.contract.push(contract);
                    self.groups.sealed.push(sealed);
                    self.groups.need.push(need);
                    if let Some(contract) = contract {
                        if let Some(previous) = self.open_group[contract as usize] {
                            self.groups.sealed[previous as usize] = true;
                        }
                        if !sealed {
                            self.open_group[contract as usize] = Some(group);
                        }
                    }
                }
            }
        }
    }

    fn requests_of(&self, need: u32) -> impl Iterator<Item = &Request> {
        self.requests
            .in_flight()
            .filter(move |request| request.needs.contains(&need))
    }

    /// The highest block the need has covered or has a bounded request out
    /// to. None while an open-ended request is out: nobody knows yet how far
    /// it reaches.
    pub fn requested_through(&self, need: u32) -> Option<i64> {
        let mut through = self.needs.coverage[need as usize].highest();
        for request in self.requests_of(need) {
            through = through.max(request.to_block?);
        }
        Some(through)
    }

    /// The covered blocks and the ones out in a request, for the need. A
    /// request out that isn't a chunk takes everything from its start.
    pub fn taken(&self, need: u32) -> Ranges {
        let mut ranges = self.needs.coverage[need as usize].ranges();
        for request in self.requests_of(need) {
            let to_block = match request.to_block {
                Some(to_block) if request.chunk => to_block,
                _ => i64::MAX,
            };
            ranges.push((request.from_block, to_block));
        }
        union(ranges)
    }

    pub fn taken_by_all(&self, needs: &[u32]) -> Ranges {
        let mut needs = needs.iter();
        let Some(&first) = needs.next() else {
            return Vec::new();
        };
        if needs.len() == 0 {
            return self.taken(first);
        }
        // Past its end a need takes nothing more, so it holds back no other
        // need of its stream there.
        let taken_to_end = |need: u32| {
            let mut taken = self.taken(need);
            if let Some(to_block) = self.needs.to_block[need as usize] {
                taken = union([taken, vec![(to_block + 1, i64::MAX)]].concat());
            }
            taken
        };
        needs.fold(taken_to_end(first), |taken, &need| {
            intersection(&taken, &taken_to_end(need))
        })
    }

    /// The block every need of the head stream has been asked through. None
    /// while an open-ended request of it is out, or with no such need.
    fn head_requested_through(&self) -> Option<i64> {
        let mut through: Option<i64> = None;
        for need in self.unfinished_needs() {
            if self.needs.is_list(need) {
                continue;
            }
            let need_through = self.requested_through(need)?;
            through = Some(through.map_or(need_through, |t| t.min(need_through)));
        }
        through
    }

    pub fn unfinished_needs(&self) -> impl Iterator<Item = u32> + '_ {
        (0..self.needs.len()).filter(|&need| !self.needs.is_finished(need))
    }

    /// The lowest block any need has fetched through.
    pub fn lowest_covered(&self) -> Option<i64> {
        self.unfinished_needs()
            .map(|need| self.needs.coverage[need as usize].covered_through)
            .min()
    }

    /// The latest block whose items are all in the buffer: the lowest need's
    /// coverage, capped at the head, below an address still waiting to join
    /// and below the lowest block whose contractRegister hasn't run. The head
    /// cap matters because a need can sit past it, on a response that reported
    /// a block the chain hadn't heard of yet or on a start block the chain
    /// hasn't reached. Before any height is known the chain has nothing before
    /// its start block to hand out.
    pub fn ready_through_block(&self) -> i64 {
        let head_cap = if self.known_height > 0 {
            self.known_height
        } else {
            self.config.start_block - 1
        };
        let mut ready = self
            .lowest_covered()
            .map_or(head_cap, |covered| covered.min(head_cap));
        for join in &self.pending_joins {
            ready = ready.min(join.start_block - 1);
        }
        if let Some(&lowest) = self.backlog.first() {
            ready = ready.min(lowest - 1);
        }
        ready
    }

    pub fn head_fetch_target(&self) -> i64 {
        self.known_height - self.block_lag - self.blocks_behind_head_allowed_by_throttle()
    }

    /// A throttled chain lets `block_throttle - 1` new blocks build up before
    /// it fetches them, so a frontier that far behind the lagged head is
    /// waiting, not behind. An end block the head has reached is fetched
    /// without waiting.
    pub fn blocks_behind_head_allowed_by_throttle(&self) -> i64 {
        match self.end_block {
            Some(end_block) if self.known_height - self.block_lag >= end_block => 0,
            _ => (self.config.block_throttle - 1).max(0),
        }
    }

    pub fn set_known_height(&mut self, known_height: i64) -> Vec<Notice> {
        if known_height <= self.known_height {
            return Vec::new();
        }
        self.known_height = known_height;
        self.enter_head_mode_when_near()
    }

    /// Rule 3. Judged only when the chain learns a newer head: an RPC response
    /// repeats the height its query went out with, which can be hours old by
    /// the end of a backfill.
    fn enter_head_mode_when_near(&mut self) -> Vec<Notice> {
        if self.head_mode || self.known_height == 0 {
            return Vec::new();
        }
        if self
            .end_block
            .is_some_and(|end_block| end_block <= self.known_height - self.block_lag)
        {
            return Vec::new();
        }
        if self
            .lowest_covered()
            .is_some_and(|covered| self.head_fetch_target() - covered > HEAD_DISTANCE)
        {
            return Vec::new();
        }
        self.head_mode = true;
        let dynamic: Vec<u32> = (0..self.dynamic.len() as u32)
            .filter(|&c| self.dynamic[c as usize] && !self.address_free[c as usize])
            .collect();
        if dynamic.is_empty() {
            return Vec::new();
        }
        self.switch_to_address_free(&dynamic, None);
        let names = self.store.read().unwrap().contract_names().to_vec();
        vec![Notice::WentAddressFreeNearHead {
            contract_names: dynamic.iter().map(|&c| names[c as usize].clone()).collect(),
        }]
    }

    /// Rule 6: each of the contracts' groups ends at the block it was
    /// requested through, and one address-free need starts from the lowest of
    /// those. The overlap above it is deduped when pages merge. With
    /// `from_block`, the need starts no later than it: past the threshold a
    /// batch's addresses are read address-free from their start, which also
    /// serves a `where` relating two of the contract's addresses.
    fn switch_to_address_free(&mut self, contracts: &[u32], from_block: Option<i64>) {
        let mut lowest = i64::MAX;
        let mut registrations = Vec::new();
        for &contract in contracts {
            self.address_free[contract as usize] = true;
            self.open_group[contract as usize] = None;
            registrations.extend(self.address_events_of(contract));
        }
        let store = self.store.clone();
        let store = store.read().unwrap();
        // A group holding other contracts' addresses too carries on with them;
        // the switched ones split off into a group of their own that ends.
        let mut ending: Vec<(Vec<Id>, Option<u32>, i64, u32)> = Vec::new();
        let mut ended: Vec<u32> = Vec::new();
        for group in 0..self.groups.ids.len() {
            let need = self.groups.need[group];
            if !self.needs.live[need as usize] || self.needs.is_finished(need) {
                continue;
            }
            let (switched, others): (Vec<Id>, Vec<Id>) = self.groups.ids[group]
                .iter()
                .partition(|&&id| contracts.contains(&store.contract_of(id)));
            if switched.is_empty() {
                continue;
            }
            let through = self
                .requested_through(need)
                .unwrap_or(self.known_height)
                .max(self.needs.coverage[need as usize].covered_through);
            lowest = lowest.min(through);
            self.groups.sealed[group] = true;
            let ends_at = self.needs.to_block[need as usize];
            if others.is_empty() || ends_at.is_some_and(|to| to <= through) {
                self.needs.to_block[need as usize] =
                    Some(ends_at.map_or(through, |to| to.min(through)));
                ended.push(need);
                continue;
            }
            let contract_of_all = |ids: &[Id]| {
                let first = store.contract_of(ids[0]);
                ids.iter()
                    .all(|&id| store.contract_of(id) == first)
                    .then_some(first)
            };
            self.groups.contract[group] = contract_of_all(&others);
            self.groups.ids[group] = others;
            ending.push((switched.clone(), contract_of_all(&switched), through, need));
        }
        drop(store);
        for (ids, contract, through, carrying_on) in ending {
            let group = self.groups.ids.len() as u32;
            let n = carrying_on as usize;
            let need = self.add_need(
                match &self.needs.what[n] {
                    What::Logs { registrations, .. } => What::Logs {
                        registrations: registrations.clone(),
                        addresses: Addresses::Group(group),
                    },
                    other => other.clone(),
                },
                self.needs.floor[n],
                self.needs.floor[n],
                Some(through),
            );
            let m = need as usize;
            self.needs.coverage[m] = self.needs.coverage[n].clone();
            self.needs.learned[m] = self.needs.learned[n].clone();
            self.needs.ever_requested[m] = self.needs.ever_requested[n];
            for request in self.requests.slots.iter_mut().flatten() {
                if request.needs.contains(&carrying_on) {
                    request.needs.push(need);
                }
            }
            self.groups.ids.push(ids);
            self.groups.contract.push(contract);
            self.groups.sealed.push(true);
            self.groups.need.push(need);
            ended.push(need);
        }
        if let Some(from_block) = from_block {
            lowest = lowest.min(from_block - 1);
        }
        // The address-free need reads every ended group's addresses from
        // `lowest` on, so none of them asks by address past it again.
        for need in ended {
            let to_block = &mut self.needs.to_block[need as usize];
            *to_block = Some(to_block.map_or(lowest, |to| to.min(lowest)));
        }
        // With no group to end, a contract switched at the head joins the head
        // stream where it has been asked through; its addresses owe what lies
        // below as catch-ups.
        if lowest == i64::MAX && self.head_mode {
            if let Some(through) = self.head_requested_through() {
                lowest = through;
            }
        }
        if lowest == i64::MAX {
            let store = self.store.read().unwrap();
            for &contract in contracts {
                if let Some(&id) = store.live_ids_of_contract(contract, 0).first() {
                    lowest = lowest.min(store.effective_start_block_of(id) - 1);
                }
            }
        }
        if lowest == i64::MAX || registrations.is_empty() {
            return;
        }
        registrations.sort_unstable();
        let floor = self.events_floor(&registrations).unwrap_or(i64::MIN);
        let end_block = contracts
            .iter()
            .map(|&c| self.config.contract_end_blocks[c as usize])
            .reduce(|a, b| match (a, b) {
                (Some(a), Some(b)) => Some(a.max(b)),
                _ => None,
            })
            .flatten();
        let need = self.add_need(
            What::Logs {
                registrations,
                addresses: Addresses::Free,
            },
            floor.min(lowest),
            lowest,
            end_block,
        );
        for &contract in contracts {
            self.address_free_need[contract as usize] = Some(need);
        }
    }

    /// Takes a batch's registrations into the store, then rule 4 for each
    /// contract they add addresses to.
    pub fn register(
        &mut self,
        registrations: Vec<AddressRegistration>,
    ) -> Result<Vec<Notice>, String> {
        let mut notices = Vec::new();
        if registrations.is_empty() {
            return Ok(notices);
        }
        let first_new_id = self.store.read().unwrap().id_count();
        let verdicts = AddressStore::from_handle(self.store.clone())
            .register_all(
                registrations
                    .iter()
                    .map(|reg| AddressRegistration {
                        address: reg.address.clone(),
                        contract_name: reg.contract_name.clone(),
                        registration_block: reg.registration_block,
                    })
                    .collect(),
                true,
            )
            .map_err(|error| error.reason.clone())?;
        let mut registering: Vec<u32> = Vec::new();
        {
            let store = self.store.read().unwrap();
            let mut next_id = first_new_id;
            for (reg, (verdict, retired)) in registrations.iter().zip(verdicts) {
                if verdict.kind == VERDICT_ADDED {
                    if let Some(retired) = retired {
                        self.replaced.push((next_id, retired));
                    }
                    next_id += 1;
                }
                if verdict.kind == VERDICT_INVALID {
                    notices.push(Notice::SkippedInvalidAddress {
                        contract_name: reg.contract_name.clone(),
                        address: reg.address.clone(),
                    });
                } else if verdict.kind == VERDICT_ADDED && verdict.fetchable {
                    let contract = store
                        .contract_idx(&reg.contract_name)
                        .expect("the store validated the contract name");
                    if !registering.contains(&contract) {
                        registering.push(contract);
                    }
                }
            }
        }
        let mut switching = Vec::new();
        for &contract in &registering {
            self.dynamic[contract as usize] = true;
            if self.address_free[contract as usize] {
                continue;
            }
            if self.head_mode {
                switching.push(contract);
                continue;
            }
            if let Some(threshold) = self.config.address_free_threshold {
                let address_count = self.store.read().unwrap().live_count_of(contract);
                if address_count > threshold {
                    switching.push(contract);
                    notices.push(Notice::SwitchedToAddressFree {
                        contract_name: self.store.read().unwrap().contract_names()
                            [contract as usize]
                            .clone(),
                        address_count,
                        threshold,
                    });
                }
            }
        }
        if !switching.is_empty() {
            // At the head a switched contract joins the head stream instead.
            let from_block = (!self.head_mode)
                .then(|| {
                    let store = self.store.read().unwrap();
                    switching
                        .iter()
                        .flat_map(|&contract| store.live_ids_of_contract(contract, first_new_id))
                        .map(|id| store.effective_start_block_of(id))
                        .min()
                })
                .flatten();
            self.switch_to_address_free(&switching, from_block);
        }
        for contract in registering {
            let ids = self
                .store
                .read()
                .unwrap()
                .live_ids_of_contract(contract, first_new_id);
            if !ids.is_empty() {
                self.join(contract, ids);
            }
        }
        Ok(notices)
    }

    fn start_block_of(&self, ids: &[Id]) -> i64 {
        let store = self.store.read().unwrap();
        ids.iter()
            .map(|&id| store.effective_start_block_of(id))
            .min()
            .unwrap_or(i64::MAX)
    }

    /// What `ids` owe below `through`, the block their forward need has been
    /// asked through.
    fn add_catch_up(&mut self, contract: u32, ids: Vec<Id>, through: i64, joins: u32) {
        let start_block = self.start_block_of(&ids);
        if start_block > through {
            return;
        }
        let registrations = self.address_events_of(contract);
        let floor = (start_block - 1).max(self.events_floor(&registrations).unwrap_or(i64::MIN));
        let to_block = match self.config.contract_end_blocks[contract as usize] {
            Some(end) => end.min(through),
            None => through,
        };
        // An address registered again from an earlier block owes only what
        // lies below its retired entry's block: that entry's needs fetch the rest.
        let store = self.store.read().unwrap();
        let fetched_from = ids
            .iter()
            .map(|id| {
                self.replaced
                    .iter()
                    .find(|(registered, _)| registered == id)
                    .map(|&(_, retired)| store.effective_start_block_of(retired))
            })
            .collect::<Option<Vec<i64>>>()
            .and_then(|starts| starts.into_iter().max());
        drop(store);
        let need = self.add_need(
            What::Logs {
                registrations,
                addresses: Addresses::List(ids),
            },
            floor,
            floor,
            Some(to_block),
        );
        self.needs.joins[need as usize] = Some(joins);
        if let Some(fetched_from) = fetched_from {
            self.needs.coverage[need as usize].add(fetched_from, to_block);
        }
    }

    fn new_group(&mut self, contract: u32, ids: Vec<Id>, covered_through: Option<i64>) -> u32 {
        let start_block = self.start_block_of(&ids);
        let registrations = self.address_events_of(contract);
        let floor = (start_block - 1).max(self.events_floor(&registrations).unwrap_or(i64::MIN));
        let group = self.groups.ids.len() as u32;
        let sealed = ids.len() >= self.config.max_group_size.max(1);
        let need = self.add_need(
            What::Logs {
                registrations,
                addresses: Addresses::Group(group),
            },
            floor,
            covered_through.unwrap_or(floor),
            self.config.contract_end_blocks[contract as usize],
        );
        self.groups.ids.push(ids);
        self.groups.contract.push(Some(contract));
        self.groups.sealed.push(sealed);
        self.groups.need.push(need);
        self.open_group[contract as usize] = (!sealed).then_some(group);
        need
    }

    /// Rule 4: addresses join their contract's forward need at the block it
    /// has been asked through, J, and owe one list need for what lies below.
    /// While an open-ended request of that need is out, J isn't known: the join
    /// waits for it, holding the frontier at the addresses' start.
    fn join(&mut self, contract: u32, ids: Vec<Id>) {
        let start_block = self.start_block_of(&ids);
        if self.address_free[contract as usize] {
            let Some(forward) = self.address_free_need[contract as usize] else {
                return;
            };
            match self.requested_through(forward) {
                Some(through) => self.add_catch_up(contract, ids, through, forward),
                None => self.pending_joins.push(PendingJoin {
                    contract,
                    ids,
                    start_block,
                }),
            }
            return;
        }
        let Some(group) = self.open_group[contract as usize] else {
            self.add_groups(contract, ids, None);
            return;
        };
        let need = self.groups.need[group as usize];
        if !self.needs.ever_requested[need as usize] {
            let room = self.config.max_group_size.max(1) - self.groups.ids[group as usize].len();
            let (joining, rest) = ids.split_at(room.min(ids.len()));
            self.add_members(group, joining);
            let floor = self.needs.floor[need as usize].min(self.start_block_of(joining) - 1);
            self.needs.floor[need as usize] = floor;
            let coverage = &mut self.needs.coverage[need as usize];
            coverage.covered_through = coverage.covered_through.min(floor);
            if !rest.is_empty() {
                self.add_groups(contract, rest.to_vec(), None);
            }
            return;
        }
        let Some(through) = self.requested_through(need) else {
            self.pending_joins.push(PendingJoin {
                contract,
                ids,
                start_block,
            });
            return;
        };
        let room = self.config.max_group_size.max(1) - self.groups.ids[group as usize].len();
        let (joining, rest) = ids.split_at(room.min(ids.len()));
        if !joining.is_empty() {
            self.add_members(group, joining);
            self.add_catch_up(contract, joining.to_vec(), through, need);
        }
        if !rest.is_empty() {
            let rest = rest.to_vec();
            let forward = self.add_groups(contract, rest.clone(), Some(through));
            self.add_catch_up(contract, rest, through, forward);
        }
    }

    /// Seals the group once it is full.
    fn add_members(&mut self, group: u32, ids: &[Id]) {
        let store = self.store.clone();
        let store = store.read().unwrap();
        let members = &mut self.groups.ids[group as usize];
        members.extend_from_slice(ids);
        store.sort_in_set_order(members);
        if members.len() >= self.config.max_group_size.max(1) {
            self.groups.sealed[group as usize] = true;
            if let Some(contract) = self.groups.contract[group as usize] {
                self.open_group[contract as usize] = None;
            }
        }
    }

    /// New groups for `ids`, from their start or from `covered_through`; all
    /// but the last full. Returns the last one's need.
    fn add_groups(&mut self, contract: u32, ids: Vec<Id>, covered_through: Option<i64>) -> u32 {
        let max = self.config.max_group_size.max(1);
        let mut need = 0;
        for chunk in ids.chunks(max) {
            need = self.new_group(contract, chunk.to_vec(), covered_through);
        }
        need
    }

    fn resolve_pending_joins(&mut self) {
        if self.pending_joins.is_empty() {
            return;
        }
        let pending = std::mem::take(&mut self.pending_joins);
        for join in pending {
            self.join(join.contract, join.ids);
        }
    }

    pub fn has_backlog(&self) -> bool {
        !self.backlog.is_empty()
    }

    pub fn take_contract_register_blocks(&mut self) -> Vec<i64> {
        self.run_readded = Some(Vec::new());
        self.backlog.clone()
    }

    pub fn complete_contract_register_run(
        &mut self,
        block_numbers: &[i64],
        registrations: Vec<AddressRegistration>,
    ) -> Result<Vec<Notice>, String> {
        let notices = self.register(registrations)?;
        let readded = self.run_readded.take().unwrap_or_default();
        self.backlog
            .retain(|block| !block_numbers.contains(block) || readded.contains(block));
        Ok(notices)
    }

    fn add_to_backlog(&mut self, blocks: &[i64]) {
        if blocks.is_empty() {
            return;
        }
        if let Some(readded) = &mut self.run_readded {
            readded.extend_from_slice(blocks);
        }
        self.backlog.extend_from_slice(blocks);
        self.backlog.sort_unstable();
        self.backlog.dedup();
    }

    /// Rule 1: a response covers what the source reports it reached, never
    /// what was asked.
    pub fn complete(
        &mut self,
        slot: u32,
        generation: u32,
        page: &Page,
        latest_fetched_block: i64,
        source: usize,
        reported_known_height: i64,
    ) -> (Option<Completion>, Vec<Notice>) {
        let Some(request) = self.requests.take(slot, generation) else {
            return (None, Vec::new());
        };
        let merged = self.buffer.merge_page(
            page,
            (reported_known_height - self.config.max_reorg_depth).max(0),
            !self.config.should_rollback_on_reorg,
        );
        if merged.mismatch.is_some() && self.config.should_rollback_on_reorg {
            return (
                Some(Completion {
                    mismatch: merged.mismatch,
                    rows_kept: merged.rows_kept,
                    registering_block_count: 0,
                }),
                Vec::new(),
            );
        }
        self.add_to_backlog(&merged.registering_block_numbers);
        let block_registrations: Vec<u32> = if request
            .needs
            .iter()
            .any(|&need| self.needs.what[need as usize] == What::Blocks)
        {
            self.config.blocks.iter().map(|reg| reg.index).collect()
        } else {
            Vec::new()
        };
        let block_handler_runs = if block_registrations.is_empty() {
            0
        } else {
            self.buffer.count_block_handler_runs_in_block_range(
                request.from_block,
                latest_fetched_block,
                block_registrations,
            )
        };
        let items = merged.rows_kept + block_handler_runs;
        self.learn(&request, latest_fetched_block, items, source);
        for &need in &request.needs {
            let n = need as usize;
            if !self.needs.live[n] {
                continue;
            }
            let to = self.needs.to_block[n]
                .map_or(latest_fetched_block, |to| to.min(latest_fetched_block));
            self.needs.coverage[n].add(request.from_block, to);
        }
        self.last_source = source;
        let notices = self.set_known_height(reported_known_height);
        self.resolve_pending_joins();
        (
            Some(Completion {
                mismatch: merged.mismatch,
                rows_kept: merged.rows_kept,
                registering_block_count: merged.registering_block_numbers.len() as u32,
            }),
            notices,
        )
    }

    pub fn abandon(&mut self, slot: u32, generation: u32) {
        if self.requests.take(slot, generation).is_some() {
            self.resolve_pending_joins();
        }
    }

    pub fn abandon_all(&mut self) {
        self.requests.drop_all();
        self.resolve_pending_joins();
    }

    fn learned_mut(&mut self, request: &Request) -> Option<&mut Learned> {
        if request.head {
            Some(&mut self.head_learned)
        } else {
            // A request shared by a need and the one a switch split off from it
            // learns for the first.
            request
                .needs
                .first()
                .map(|&need| &mut self.needs.learned[need as usize])
        }
    }

    /// Density from every response; a source's range capacity only from one
    /// that measured it: the source cut the range short, or answered a whole
    /// range at least as long as the chunks it sizes.
    fn learn(&mut self, request: &Request, latest_fetched_block: i64, items: u32, source: usize) {
        let known_height = self.known_height;
        let Some(learned) = self.learned_mut(request) else {
            return;
        };
        let block_range = latest_fetched_block - request.from_block + 1;
        let observed = f64::from(items) / block_range as f64;
        learned.density = Some(match learned.density {
            None => observed,
            Some(density) => (density + observed) / 2.,
        });
        if learned.capacity.len() <= source {
            learned.capacity.resize(source + 1, Capacity::default());
        }
        let capacity = &mut learned.capacity[source];
        let measured = latest_fetched_block > capacity.updated_at_block
            && match request.to_block {
                None => latest_fetched_block < known_height - 10,
                Some(to_block) if latest_fetched_block < to_block => true,
                Some(to_block) => capacity
                    .chunk_range()
                    .is_some_and(|range| to_block - request.from_block + 1 >= range),
            };
        if measured {
            capacity.previous = capacity.last;
            capacity.last = block_range;
            capacity.updated_at_block = latest_fetched_block;
        }
    }

    /// Rule 7. Every request out is dropped: the loop discards their
    /// responses, since they were asked against the state being rolled back.
    pub fn rollback(&mut self, target_block: i64) -> Vec<crate::address_store::RolledBackAddress> {
        let rolled_back = AddressStore::from_handle(self.store.clone()).rollback(target_block);
        self.requests.drop_all();
        let store = self.store.clone();
        let store = store.read().unwrap();
        let kept = |id: Id| store.registration_block_of(id) <= target_block;
        self.replaced.retain(|&(registered, retired)| {
            store.is_live(registered) && kept(registered) && kept(retired)
        });
        let replaced = &self.replaced;
        let survives = |id: &Id| {
            kept(*id) && (store.is_live(*id) || replaced.iter().any(|&(_, retired)| retired == *id))
        };
        for group in 0..self.groups.ids.len() {
            self.groups.ids[group].retain(survives);
            if self.groups.ids[group].is_empty() {
                let need = self.groups.need[group] as usize;
                self.needs.live[need] = false;
                if let Some(contract) = self.groups.contract[group] {
                    if self.open_group[contract as usize] == Some(group as u32) {
                        self.open_group[contract as usize] = None;
                    }
                }
            }
        }
        for need in 0..self.needs.len() as usize {
            if let What::Logs {
                addresses: Addresses::List(ids),
                ..
            } = &mut self.needs.what[need]
            {
                ids.retain(survives);
                if ids.is_empty() {
                    self.needs.live[need] = false;
                }
            }
        }
        for need in 0..self.needs.len() as usize {
            if !self.needs.live[need] {
                continue;
            }
            // A need fetched by address lost the addresses registered past the
            // target, so what it measured no longer prices its requests.
            let by_address = !matches!(
                self.needs.what[need],
                What::Logs {
                    addresses: Addresses::Free,
                    ..
                } | What::Blocks
                    | What::Transactions
            );
            if by_address && self.needs.coverage[need].highest() > target_block {
                self.needs.learned[need] = Learned::default();
                self.head_learned = Learned::default();
            }
            self.needs.coverage[need].clip(target_block, self.needs.floor[need]);
            if let (Some(to_block), Some(joins)) =
                (self.needs.to_block[need], self.needs.joins[need])
            {
                let joined_from = self.needs.floor[joins as usize] + 1;
                self.needs.to_block[need] = Some(to_block.min(target_block.max(joined_from - 1)));
            }
        }
        for join in &mut self.pending_joins {
            join.ids.retain(survives);
        }
        self.pending_joins.retain(|join| !join.ids.is_empty());
        drop(store);
        for join in 0..self.pending_joins.len() {
            let start_block = self.start_block_of(&self.pending_joins[join].ids);
            self.pending_joins[join].start_block = start_block;
        }
        self.backlog.retain(|&block| block <= target_block);
        rolled_back
    }

    /// The streams of requests a chain runs, by what they carry.
    pub fn streams(&self) -> Vec<(Vec<u32>, bool)> {
        if !self.head_mode {
            return self
                .unfinished_needs()
                .map(|need| (vec![need], false))
                .collect();
        }
        let mut forward = Vec::new();
        let mut streams = Vec::new();
        for need in self.unfinished_needs() {
            let apart = self.needs.is_list(need)
                || (self.config.blocks_apart && self.needs.what[need as usize] == What::Blocks);
            if apart {
                streams.push((vec![need], false));
            } else {
                forward.push(need);
            }
        }
        if !forward.is_empty() {
            streams.insert(0, (forward, true));
        }
        streams
    }
}
