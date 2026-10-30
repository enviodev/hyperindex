//! The test double that stands in for a chain's data source.
//!
//! It is the ledger of everything the indexer has asked a source and the test
//! has not answered yet — height calls, item queries, block-hash lookups — and
//! it decides what a test's expectations match and what is wrong with them. It
//! answers nothing itself. Every call is recorded under an id, and every answer
//! a test gives comes back as the ids to settle, so whoever holds the pending
//! callers settles them. The JS shim implementing `Source.t` holds them as
//! promise resolvers and settles them synchronously, so an answer reaches the
//! indexer within the microtask the test gave it in; tests rely on that order.
//!
//! What only JS can hold stays there: the reply items, which carry handler
//! functions; a test's `where` predicates, which the shim runs on the
//! candidates `entry_candidates` names and passes back as the ids they
//! accepted; and the failures a test rejects with.

use std::collections::{HashSet, VecDeque};

use napi_derive::napi;

/// An answer for a height call startup makes before a test body can answer it.
#[napi(object)]
#[derive(Clone)]
pub struct MockStartupHeight {
    pub height: Option<i64>,
    pub failure: Option<String>,
}

/// What a height call got on arrival. With neither field set it is parked
/// under `index` until a test answers it.
#[napi(object)]
pub struct MockHeightCall {
    pub index: u32,
    pub height: Option<i64>,
    pub failure: Option<String>,
}

#[napi(object)]
#[derive(Clone, Debug, PartialEq)]
pub struct MockItemsQuery {
    pub id: u32,
    pub partition_id: String,
    pub from_block: i64,
    /// Absent for a query that runs to the head.
    pub to_block: Option<i64>,
    pub retry_count: u32,
    /// Lowercase, as an entry's `address` is compared.
    pub addresses: Vec<String>,
    /// The chain height the indexer knew when it sent the query.
    pub known_height: i64,
}

/// One entry of a test's `expectItemsQueries` list, as data. `where_ids` are
/// the pending queries the entry's `where` predicate accepted, present only
/// when it has one.
#[napi(object)]
#[derive(Clone, Default)]
pub struct MockExpectedQuery {
    pub partition_id: Option<String>,
    pub from_block: Option<i64>,
    pub to_block: Option<i64>,
    pub to_block_unbounded: Option<bool>,
    pub retry_count: Option<u32>,
    pub covers_block: Option<i64>,
    /// An address the query fetches for, in any letter case.
    pub address: Option<String>,
    pub where_ids: Option<Vec<u32>>,
    /// The reply's constructor name: `Respond`, `RespondWith`,
    /// `RespondUnchecked`, `Fail` or `LeavePending`.
    pub reply: String,
}

/// `matched`: `assignment` gives each replying entry, in list order, the query
/// it replies to, and `left_pending` the queries the rest account for. `wait`:
/// nothing matches yet, and `message` is what to say if nothing ever does.
/// `error`: the list itself is wrong, and `message` says how.
#[napi(object)]
pub struct MockItemsMatch {
    pub status: String,
    pub assignment: Vec<u32>,
    pub left_pending: Vec<u32>,
    pub message: Option<String>,
}

/// A reply about to be given, for the checks a real source's reply passes.
#[napi(object)]
pub struct MockItemsReply {
    pub id: u32,
    pub checked: bool,
    pub is_failure: bool,
    pub latest_fetched_block_number: Option<i64>,
    pub item_block_numbers: Vec<i64>,
}

#[napi(object)]
pub struct MockDrainReply {
    pub id: u32,
    pub latest_fetched_block_number: Option<i64>,
}

#[napi(object)]
pub struct MockHeightCallsCheck {
    pub done: bool,
    pub error: Option<String>,
}

/// `status` is `matched` with the lookup's `id`, `wait`, or `error`.
#[napi(object)]
pub struct MockLookupMatch {
    pub status: String,
    pub id: Option<u32>,
    pub message: Option<String>,
}

struct Lookup {
    id: u32,
    block_numbers: Vec<i64>,
}

struct DeferredHeight {
    site: String,
    height: i64,
}

const QUERY_FIELDS: [&str; 4] = ["partitionId", "fromBlock", "toBlock", "retryCount"];

#[derive(Default)]
struct Ledger {
    chain_id: u32,
    auto_height: Option<i64>,
    startup_heights: VecDeque<MockStartupHeight>,
    /// One entry per height call taken, in arrival order, so an index is the
    /// call number a test counted. `true` while it waits for an answer.
    height_calls: Vec<bool>,
    /// Height answers given before their call arrived, claimed in order.
    deferred_heights: VecDeque<DeferredHeight>,
    next_id: u32,
    pending_queries: Vec<MockItemsQuery>,
    /// Queries an earlier expectation left pending. A later one doesn't have to
    /// name them again to account for them.
    kept_queries: HashSet<u32>,
    pending_lookups: Vec<Lookup>,
    reorg_calls: u32,
}

fn describe_to_block(to_block: Option<i64>) -> String {
    match to_block {
        Some(to_block) => format!("Bounded({to_block})"),
        None => "Unbounded".to_string(),
    }
}

fn query_field(query: &MockItemsQuery, name: &str) -> String {
    match name {
        "partitionId" => format!("\"{}\"", query.partition_id),
        "fromBlock" => query.from_block.to_string(),
        "toBlock" => describe_to_block(query.to_block),
        _ => query.retry_count.to_string(),
    }
}

// Pasteable as an entry, so a failure's suggestion can go straight into the test.
fn describe_query(query: &MockItemsQuery, fields: &[&str], reply: Option<&str>) -> String {
    let mut parts: Vec<String> = fields
        .iter()
        .map(|name| format!("{name}: {}", query_field(query, name)))
        .collect();
    if let Some(reply) = reply {
        parts.push(format!("reply: {reply}"));
    }
    format!("{{{}}}", parts.join(", "))
}

fn describe_queries<'a>(queries: impl IntoIterator<Item = &'a MockItemsQuery>) -> String {
    let lines: Vec<String> = queries
        .into_iter()
        .map(|query| format!("  {}", describe_query(query, &QUERY_FIELDS, None)))
        .collect();
    if lines.is_empty() {
        "  none".to_string()
    } else {
        lines.join("\n")
    }
}

fn describe_block_numbers(block_numbers: &[i64]) -> String {
    let numbers: Vec<String> = block_numbers.iter().map(i64::to_string).collect();
    format!("[{}]", numbers.join(", "))
}

fn is_replying(entry: &MockExpectedQuery) -> bool {
    entry.reply != "LeavePending"
}

fn describe_expected(entry: &MockExpectedQuery) -> String {
    let mut parts = Vec::new();
    if let Some(partition_id) = &entry.partition_id {
        parts.push(format!("partitionId: \"{partition_id}\""));
    }
    if let Some(from_block) = entry.from_block {
        parts.push(format!("fromBlock: {from_block}"));
    }
    if let Some(to_block) = expected_to_block(entry) {
        parts.push(format!("toBlock: {}", describe_to_block(to_block)));
    }
    if let Some(retry_count) = entry.retry_count {
        parts.push(format!("retryCount: {retry_count}"));
    }
    if let Some(covers_block) = entry.covers_block {
        parts.push(format!("coversBlock: {covers_block}"));
    }
    if let Some(address) = &entry.address {
        parts.push(format!("address: \"{address}\""));
    }
    if entry.where_ids.is_some() {
        parts.push("where: <fn>".to_string());
    }
    let reply = match entry.reply.as_str() {
        "LeavePending" => "LeavePending".to_string(),
        name => format!("{name}(…)"),
    };
    parts.push(format!("reply: {reply}"));
    format!("{{{}}}", parts.join(", "))
}

/// The `toBlock` an entry pins, if any: `Some(None)` for an unbounded query.
fn expected_to_block(entry: &MockExpectedQuery) -> Option<Option<i64>> {
    if entry.to_block_unbounded == Some(true) {
        Some(None)
    } else {
        entry.to_block.map(Some)
    }
}

fn covers_block(query: &MockItemsQuery, block_number: i64) -> bool {
    query.from_block <= block_number && query.to_block.is_none_or(|to| block_number <= to)
}

// Everything but `where`, which only the shim can run.
fn fields_match(entry: &MockExpectedQuery, query: &MockItemsQuery) -> bool {
    entry
        .partition_id
        .as_ref()
        .is_none_or(|id| *id == query.partition_id)
        && entry.from_block.is_none_or(|from| from == query.from_block)
        && expected_to_block(entry).is_none_or(|to| to == query.to_block)
        && entry
            .retry_count
            .is_none_or(|retry| retry == query.retry_count)
        && entry
            .covers_block
            .is_none_or(|block| covers_block(query, block))
        && entry.address.as_ref().is_none_or(|address| {
            let address = address.to_lowercase();
            query.addresses.contains(&address)
        })
}

fn entry_matches(entry: &MockExpectedQuery, query: &MockItemsQuery) -> bool {
    fields_match(entry, query)
        && entry
            .where_ids
            .as_ref()
            .is_none_or(|ids| ids.contains(&query.id))
}

// Every way to give each replying entry its own pending query, stopping at two:
// one is the answer, two means the list leaves the choice to arrival order.
fn reply_assignments(replying: &[&MockExpectedQuery], queries: &[MockItemsQuery]) -> Vec<Vec<u32>> {
    fn assign(
        index: usize,
        replying: &[&MockExpectedQuery],
        queries: &[MockItemsQuery],
        current: &mut Vec<u32>,
        found: &mut Vec<Vec<u32>>,
    ) {
        if found.len() >= 2 {
            return;
        }
        match replying.get(index) {
            None => found.push(current.clone()),
            Some(entry) => {
                for query in queries {
                    if !current.contains(&query.id) && entry_matches(entry, query) {
                        current.push(query.id);
                        assign(index + 1, replying, queries, current, found);
                        current.pop();
                    }
                }
            }
        }
    }
    let mut found = Vec::new();
    assign(0, replying, queries, &mut Vec::new(), &mut found);
    found
}

impl Ledger {
    fn next_id(&mut self) -> u32 {
        self.next_id += 1;
        self.next_id
    }

    fn query(&self, id: u32) -> Option<&MockItemsQuery> {
        self.pending_queries.iter().find(|query| query.id == id)
    }

    fn pending_height_indices(&self) -> Vec<u32> {
        self.height_calls
            .iter()
            .enumerate()
            .filter(|(_, pending)| **pending)
            .map(|(index, _)| index as u32)
            .collect()
    }

    fn settle_heights(&mut self, indices: &[u32]) {
        for index in indices {
            self.height_calls[*index as usize] = false;
        }
    }

    fn take_height_call(&mut self) -> MockHeightCall {
        let index = self.height_calls.len() as u32;
        let answer = match self.startup_heights.pop_front() {
            Some(scripted) => Some(scripted),
            None => self
                .auto_height
                .or_else(|| self.deferred_heights.pop_front().map(|d| d.height))
                .map(|height| MockStartupHeight {
                    height: Some(height),
                    failure: None,
                }),
        };
        // Recorded answered or not, so an index means the same call to the
        // ledger as it does to the test counting calls. A scripted entry with
        // nothing in it parks the call like no entry at all.
        let pending = answer
            .as_ref()
            .is_none_or(|answer| answer.height.is_none() && answer.failure.is_none());
        self.height_calls.push(pending);
        match answer {
            Some(MockStartupHeight { height, failure }) => MockHeightCall {
                index,
                height,
                failure,
            },
            None => MockHeightCall {
                index,
                height: None,
                failure: None,
            },
        }
    }

    // Answers every call in flight, or — with none in flight — the next one to
    // arrive. A chain has one head, so there is nothing to choose between.
    fn resolve_height(&mut self, height: i64, site: String) -> Vec<u32> {
        let indices = self.pending_height_indices();
        if indices.is_empty() {
            self.deferred_heights
                .push_back(DeferredHeight { site, height });
        }
        self.settle_heights(&indices);
        indices
    }

    fn resolve_height_at(&mut self, index: i64) -> Result<bool, String> {
        match usize::try_from(index)
            .ok()
            .and_then(|position| self.height_calls.get_mut(position))
        {
            None => Err(format!(
                "The source has taken no getHeightOrThrow call at index {index}"
            )),
            Some(pending) => Ok(std::mem::replace(pending, false)),
        }
    }

    fn set_auto_height(&mut self, height: i64) -> Vec<u32> {
        self.auto_height = Some(height);
        // A standing answer supersedes one parked for a single call.
        self.deferred_heights.clear();
        let indices = self.pending_height_indices();
        self.settle_heights(&indices);
        indices
    }

    fn reject_heights(&mut self) -> Vec<u32> {
        let indices = self.pending_height_indices();
        self.settle_heights(&indices);
        indices
    }

    fn check_height_calls(&self, count: u32) -> MockHeightCallsCheck {
        let taken = self.height_calls.len() as u32;
        if taken > count {
            MockHeightCallsCheck {
                done: true,
                error: Some(format!(
                    "expectHeightCalls expected {count} height calls, but the source has taken {taken}"
                )),
            }
        } else {
            MockHeightCallsCheck {
                done: taken == count,
                error: None,
            }
        }
    }

    fn height_calls_timeout_message(&self, count: u32) -> String {
        format!(
            "expectHeightCalls timed out waiting for {count} height calls; the source has taken {}",
            self.height_calls.len()
        )
    }

    fn unclaimed_answers_message(&self) -> Option<String> {
        if self.deferred_heights.is_empty() {
            return None;
        }
        let lines: Vec<String> = self
            .deferred_heights
            .iter()
            .map(|answer| format!("  resolveGetHeightOrThrow at {}", answer.site))
            .collect();
        Some(format!(
            "Chain {} registered these mock answers before their call arrived, and no call ever claimed them:\n{}",
            self.chain_id,
            lines.join("\n")
        ))
    }

    fn take_items_query(
        &mut self,
        partition_id: String,
        from_block: i64,
        to_block: Option<i64>,
        retry_count: u32,
        addresses: Vec<String>,
        known_height: i64,
    ) -> u32 {
        let id = self.next_id();
        self.pending_queries.push(MockItemsQuery {
            id,
            partition_id,
            from_block,
            to_block,
            retry_count,
            addresses,
            known_height,
        });
        id
    }

    fn settle_query(&mut self, id: u32) {
        self.pending_queries.retain(|query| query.id != id);
        self.kept_queries.remove(&id);
    }

    fn timeout_message(&self, entries: &[MockExpectedQuery], replied: Option<&[u32]>) -> String {
        let matches_some = |entry: &MockExpectedQuery| {
            self.pending_queries
                .iter()
                .any(|query| entry_matches(entry, query))
        };
        let every_reply_matches = entries
            .iter()
            .all(|entry| !is_replying(entry) || matches_some(entry));
        let lines: Vec<String> = entries
            .iter()
            .enumerate()
            .map(|(index, entry)| {
                let matching: Vec<&MockItemsQuery> = self
                    .pending_queries
                    .iter()
                    .filter(|query| entry_matches(entry, query))
                    .collect();
                let reason = if matching.is_empty() {
                    " (matches no pending query)"
                } else {
                    match replied {
                        None if is_replying(entry) && every_reply_matches => {
                            " (no query left for it once the other replies pick)"
                        }
                        Some(replied)
                            if !is_replying(entry)
                                && matching.iter().all(|query| replied.contains(&query.id)) =>
                        {
                            " (every query it matches is taken by a reply)"
                        }
                        _ => "",
                    }
                };
                format!("  #{index} {}{reason}", describe_expected(entry))
            })
            .collect();
        let some_match = entries.iter().any(matches_some);
        let some_unmatched = !entries.iter().all(matches_some);
        let follow_up_hint = if some_match && some_unmatched {
            "\nThe list replies only once every entry matches, but the indexer may send a query only after an earlier one is answered. If an unmatched entry is such a follow-up, expect it in a later expectItemsQueries call."
        } else {
            ""
        };
        format!(
            "expectItemsQueries timed out. Expected:\n{}\nPending:\n{}{follow_up_hint}",
            lines.join("\n"),
            describe_queries(&self.pending_queries)
        )
    }

    fn ambiguous_message(
        &self,
        entries: &[MockExpectedQuery],
        replying_indices: &[usize],
        first: &[u32],
        second: &[u32],
    ) -> String {
        let positions: Vec<usize> = (0..replying_indices.len())
            .filter(|position| first[*position] != second[*position])
            .collect();
        let mut ids: Vec<u32> = Vec::new();
        for position in &positions {
            for id in [first[*position], second[*position]] {
                if !ids.contains(&id) {
                    ids.push(id);
                }
            }
        }
        let queries: Vec<&MockItemsQuery> = ids.iter().filter_map(|id| self.query(*id)).collect();
        let distinguishing = QUERY_FIELDS.iter().find(|name| {
            let values: Vec<String> = queries.iter().map(|q| query_field(q, name)).collect();
            values
                .iter()
                .all(|value| values.iter().filter(|other| *other == value).count() == 1)
        });
        let entries_text: Vec<String> = positions
            .iter()
            .map(|position| {
                let index = replying_indices[*position];
                format!("entry #{index} {}", describe_expected(&entries[index]))
            })
            .collect();
        let suggestion = match distinguishing {
            Some(name) => format!(
                "\nGive each query its own entry, told apart by {name}:\n{}",
                queries
                    .iter()
                    .map(|query| format!("  {}", describe_query(query, &[name], Some("…"))))
                    .collect::<Vec<_>>()
                    .join("\n")
            ),
            None => "\nNo query field tells them apart; tell them apart with `where`, e.g. by addresses.".to_string(),
        };
        format!(
            "expectItemsQueries can reply to more than one pending query with {}:\n{}{suggestion}",
            entries_text.join(", "),
            describe_queries(queries)
        )
    }

    // Only a reply needs a query of its own: which query takes a reply is the
    // one thing arrival order must not decide. `LeavePending` hands nothing
    // out, so it accounts for every remaining query it matches.
    fn match_items_queries(&self, entries: &[MockExpectedQuery]) -> MockItemsMatch {
        let replying_indices: Vec<usize> = entries
            .iter()
            .enumerate()
            .filter(|(_, entry)| is_replying(entry))
            .map(|(index, _)| index)
            .collect();
        let replying: Vec<&MockExpectedQuery> = replying_indices
            .iter()
            .map(|index| &entries[*index])
            .collect();
        let wait = |message| MockItemsMatch {
            status: "wait".to_string(),
            assignment: vec![],
            left_pending: vec![],
            message: Some(message),
        };
        let assignments = reply_assignments(&replying, &self.pending_queries);
        match assignments.as_slice() {
            [] => wait(self.timeout_message(entries, None)),
            [assignment] => {
                let mut left_pending: Vec<u32> = Vec::new();
                for entry in entries.iter().filter(|entry| !is_replying(entry)) {
                    let accounted: Vec<u32> = self
                        .pending_queries
                        .iter()
                        .filter(|query| {
                            !assignment.contains(&query.id) && entry_matches(entry, query)
                        })
                        .map(|query| query.id)
                        .collect();
                    if accounted.is_empty() {
                        return wait(self.timeout_message(entries, Some(assignment)));
                    }
                    left_pending.extend(accounted);
                }
                let unlisted: Vec<&MockItemsQuery> = self
                    .pending_queries
                    .iter()
                    .filter(|query| {
                        !assignment.contains(&query.id)
                            && !left_pending.contains(&query.id)
                            && !self.kept_queries.contains(&query.id)
                    })
                    .collect();
                if !unlisted.is_empty() {
                    return MockItemsMatch {
                        status: "error".to_string(),
                        assignment: vec![],
                        left_pending: vec![],
                        message: Some(unlisted_message(&unlisted)),
                    };
                }
                MockItemsMatch {
                    status: "matched".to_string(),
                    assignment: assignment.clone(),
                    left_pending,
                    message: None,
                }
            }
            [first, second, ..] => MockItemsMatch {
                status: "error".to_string(),
                assignment: vec![],
                left_pending: vec![],
                message: Some(self.ambiguous_message(entries, &replying_indices, first, second)),
            },
        }
    }

    fn keep_pending(&mut self, ids: &[u32]) {
        self.kept_queries.extend(ids.iter().copied());
    }

    fn check_replies(&self, replies: &[MockItemsReply]) -> Option<String> {
        for reply in replies {
            let Some(query) = self.query(reply.id) else {
                continue;
            };
            if !reply.checked || reply.is_failure {
                continue;
            }
            let describe = describe_query(query, &QUERY_FIELDS, None);
            if let (Some(latest), Some(to_block)) =
                (reply.latest_fetched_block_number, query.to_block)
            {
                if latest > to_block {
                    return Some(format!(
                        "expectItemsQueries can't reply latestFetchedBlockNumber {latest} to {describe}: a source never fetches past the toBlock it was asked for"
                    ));
                }
            }
            let latest = reply
                .latest_fetched_block_number
                .unwrap_or(query.to_block.unwrap_or(query.from_block));
            if let Some(block) = reply
                .item_block_numbers
                .iter()
                .find(|block| **block < query.from_block || **block > latest)
            {
                let hint = if query.to_block.is_none()
                    && reply.latest_fetched_block_number.is_none()
                    && *block > latest
                {
                    format!(
                        ". The query is unbounded, so a reply without latestFetchedBlockNumber stops at its fromBlock. To fetch up to the height the indexer knew, reply latestFetchedBlockNumber: {}",
                        query.known_height
                    )
                } else {
                    String::new()
                };
                return Some(format!(
                    "expectItemsQueries can't reply an item at block {block} to {describe}: a source only returns items between the query's fromBlock and the latestFetchedBlockNumber it replies ({latest}){hint}"
                ));
            }
        }
        None
    }

    fn drain(&self, latest: Option<i64>) -> Result<Vec<MockDrainReply>, String> {
        if self.pending_queries.is_empty() {
            return Err("drainPendingItemsQueries has no pending query to drain".to_string());
        }
        for query in &self.pending_queries {
            if let (Some(latest), Some(to_block)) = (latest, query.to_block) {
                if latest > to_block {
                    return Err(format!(
                        "drainPendingItemsQueries can't reply latestFetchedBlockNumber {latest} to {}: a source never fetches past the toBlock it was asked for. Drain without ~latestFetchedBlockNumber to answer each query up to its own toBlock.",
                        describe_query(query, &QUERY_FIELDS, None)
                    ));
                }
            }
        }
        Ok(self
            .pending_queries
            .iter()
            .map(|query| MockDrainReply {
                id: query.id,
                latest_fetched_block_number: latest,
            })
            .collect())
    }

    fn take_lookup(&mut self, block_numbers: Vec<i64>) -> u32 {
        let id = self.next_id();
        self.pending_lookups.push(Lookup { id, block_numbers });
        id
    }

    fn settle_all_lookups(&mut self, caller: &str) -> Result<Vec<u32>, String> {
        if self.pending_lookups.is_empty() {
            return Err(format!("{caller} has no pending lookup to answer"));
        }
        Ok(self
            .pending_lookups
            .drain(..)
            .map(|lookup| lookup.id)
            .collect())
    }

    fn match_lookup(&mut self, block_numbers: &[i64]) -> MockLookupMatch {
        let outcome = |status: &str, id, message| MockLookupMatch {
            status: status.to_string(),
            id,
            message,
        };
        match self.pending_lookups.as_slice() {
            [] => outcome(
                "wait",
                None,
                Some(format!(
                    "expectBlockHashLookup timed out waiting for a lookup of {}. No lookup is pending.",
                    describe_block_numbers(block_numbers)
                )),
            ),
            [lookup] if lookup.block_numbers == block_numbers => {
                let id = lookup.id;
                self.pending_lookups.clear();
                outcome("matched", Some(id), None)
            }
            [lookup] => outcome(
                "error",
                None,
                Some(format!(
                    "expectBlockHashLookup expected a lookup of {}, but the pending lookup asks for {}",
                    describe_block_numbers(block_numbers),
                    describe_block_numbers(&lookup.block_numbers)
                )),
            ),
            lookups => outcome(
                "error",
                None,
                Some(format!(
                    "expectBlockHashLookup can't tell which of {} pending lookups to answer: {}",
                    lookups.len(),
                    lookups
                        .iter()
                        .map(|lookup| describe_block_numbers(&lookup.block_numbers))
                        .collect::<Vec<_>>()
                        .join(", ")
                )),
            ),
        }
    }

    fn describe_state(&self) -> String {
        let queries = if self.pending_queries.is_empty() {
            " none".to_string()
        } else {
            self.pending_queries
                .iter()
                .map(|query| format!("\n    {}", describe_query(query, &QUERY_FIELDS, None)))
                .collect()
        };
        let lookups = if self.pending_lookups.is_empty() {
            "none".to_string()
        } else {
            self.pending_lookups
                .iter()
                .map(|lookup| describe_block_numbers(&lookup.block_numbers))
                .collect::<Vec<_>>()
                .join(", ")
        };
        format!(
            "Mock source for chain {} at the failure:\n  pending item queries:{queries}\n  pending block-hash lookups: {lookups}\n  height calls taken: {}",
            self.chain_id,
            self.height_calls.len()
        )
    }

    // Voids what a stopped indexer left in flight; its restart asks again.
    fn drop_pending(&mut self) -> Vec<u32> {
        self.pending_queries.clear();
        self.kept_queries.clear();
        self.pending_lookups.clear();
        let indices = self.pending_height_indices();
        self.settle_heights(&indices);
        indices
    }
}

fn unlisted_message(unlisted: &[&MockItemsQuery]) -> String {
    let mut partition_ids: Vec<&str> = Vec::new();
    for query in unlisted {
        if !partition_ids.contains(&query.partition_id.as_str()) {
            partition_ids.push(&query.partition_id);
        }
    }
    format!(
        "expectItemsQueries matched every entry, but these pending queries are in none:\n{}\nReply to them in this list, or keep them pending:\n{}",
        describe_queries(unlisted.iter().copied()),
        partition_ids
            .iter()
            .map(|id| format!("  {{partitionId: \"{id}\", reply: LeavePending}}"))
            .collect::<Vec<_>>()
            .join("\n")
    )
}

fn reason(message: String) -> napi::Error {
    napi::Error::from_reason(message)
}

/// The ledger a test's mock source keeps. See the module docs for what it
/// holds and what it leaves to its caller.
#[napi]
pub struct MockSource {
    ledger: Ledger,
}

#[napi]
impl MockSource {
    #[napi(factory)]
    pub fn new(
        chain_id: u32,
        auto_height: Option<i64>,
        startup_heights: Vec<MockStartupHeight>,
    ) -> Self {
        MockSource {
            ledger: Ledger {
                chain_id,
                auto_height,
                startup_heights: startup_heights.into(),
                ..Ledger::default()
            },
        }
    }

    #[napi]
    pub fn take_height_call(&mut self) -> MockHeightCall {
        self.ledger.take_height_call()
    }

    #[napi]
    pub fn resolve_height(&mut self, height: i64, site: String) -> Vec<u32> {
        self.ledger.resolve_height(height, site)
    }

    /// Whether the call was still waiting. Answering one already settled does
    /// nothing; an index the source never took is an error.
    #[napi]
    pub fn resolve_height_at(&mut self, index: i64) -> napi::Result<bool> {
        self.ledger.resolve_height_at(index).map_err(reason)
    }

    #[napi]
    pub fn set_auto_height(&mut self, height: i64) -> Vec<u32> {
        self.ledger.set_auto_height(height)
    }

    #[napi]
    pub fn reject_heights(&mut self) -> Vec<u32> {
        self.ledger.reject_heights()
    }

    #[napi]
    pub fn check_height_calls(&self, count: u32) -> MockHeightCallsCheck {
        self.ledger.check_height_calls(count)
    }

    #[napi]
    pub fn height_calls_timeout_message(&self, count: u32) -> String {
        self.ledger.height_calls_timeout_message(count)
    }

    #[napi]
    pub fn unclaimed_answers_message(&self) -> Option<String> {
        self.ledger.unclaimed_answers_message()
    }

    #[napi]
    pub fn take_items_query(
        &mut self,
        partition_id: String,
        from_block: i64,
        to_block: Option<i64>,
        retry_count: u32,
        addresses: Vec<String>,
        known_height: i64,
    ) -> u32 {
        self.ledger.take_items_query(
            partition_id,
            from_block,
            to_block,
            retry_count,
            addresses,
            known_height,
        )
    }

    #[napi]
    pub fn settle_items_query(&mut self, id: u32) {
        self.ledger.settle_query(id)
    }

    /// Per entry, the pending queries its fields match, `where` aside: the only
    /// ones the shim runs that entry's `where` on, since a predicate may assume
    /// the shape the other fields guarantee.
    #[napi]
    pub fn entry_candidates(&self, entries: Vec<MockExpectedQuery>) -> Vec<Vec<u32>> {
        entries
            .iter()
            .map(|entry| {
                self.ledger
                    .pending_queries
                    .iter()
                    .filter(|query| fields_match(entry, query))
                    .map(|query| query.id)
                    .collect()
            })
            .collect()
    }

    #[napi]
    pub fn match_items_queries(&self, entries: Vec<MockExpectedQuery>) -> MockItemsMatch {
        self.ledger.match_items_queries(&entries)
    }

    #[napi]
    pub fn keep_pending(&mut self, ids: Vec<u32>) {
        self.ledger.keep_pending(&ids)
    }

    #[napi]
    pub fn check_replies(&self, replies: Vec<MockItemsReply>) -> Option<String> {
        self.ledger.check_replies(&replies)
    }

    #[napi]
    pub fn drain_items_queries(
        &self,
        latest_fetched_block_number: Option<i64>,
    ) -> napi::Result<Vec<MockDrainReply>> {
        self.ledger
            .drain(latest_fetched_block_number)
            .map_err(reason)
    }

    #[napi]
    pub fn take_block_hash_lookup(&mut self, block_numbers: Vec<i64>) -> u32 {
        self.ledger.take_lookup(block_numbers)
    }

    /// Settles every lookup in flight, failing as `caller` when there is none.
    #[napi]
    pub fn settle_all_block_hash_lookups(&mut self, caller: String) -> napi::Result<Vec<u32>> {
        self.ledger.settle_all_lookups(&caller).map_err(reason)
    }

    #[napi]
    pub fn match_block_hash_lookup(&mut self, block_numbers: Vec<i64>) -> MockLookupMatch {
        self.ledger.match_lookup(&block_numbers)
    }

    #[napi]
    pub fn record_reorg(&mut self) {
        self.ledger.reorg_calls += 1;
    }

    #[napi]
    pub fn reorg_call_count(&self) -> u32 {
        self.ledger.reorg_calls
    }

    #[napi]
    pub fn describe_state(&self) -> String {
        self.ledger.describe_state()
    }

    /// The height calls that were still waiting, now voided.
    #[napi]
    pub fn drop_pending_calls(&mut self) -> Vec<u32> {
        self.ledger.drop_pending()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ledger() -> Ledger {
        Ledger {
            chain_id: 1,
            ..Ledger::default()
        }
    }

    fn take(
        ledger: &mut Ledger,
        partition_id: String,
        from_block: i64,
        to_block: Option<i64>,
        retry_count: u32,
    ) -> u32 {
        ledger.take_items_query(partition_id, from_block, to_block, retry_count, vec![], 0)
    }

    fn reply(name: &str) -> MockExpectedQuery {
        MockExpectedQuery {
            reply: name.to_string(),
            ..MockExpectedQuery::default()
        }
    }

    #[test]
    fn answers_heights_from_script_then_standing_then_deferred() {
        let mut ledger = ledger();
        ledger.startup_heights = VecDeque::from([MockStartupHeight {
            height: None,
            failure: Some("down".to_string()),
        }]);
        let scripted = ledger.take_height_call();
        // No answer yet: the call is parked, and the next resolve settles it.
        let parked = ledger.take_height_call();
        let settled = ledger.resolve_height(7, "site".to_string());
        // Nothing in flight: the answer waits for the next call.
        let deferred = ledger.resolve_height(8, "site".to_string());
        let claimed = ledger.take_height_call();
        assert_eq!(
            (
                (scripted.index, scripted.height, scripted.failure),
                (parked.index, parked.height, parked.failure),
                settled,
                deferred,
                (claimed.index, claimed.height),
                ledger.unclaimed_answers_message(),
            ),
            (
                (0, None, Some("down".to_string())),
                (1, None, None),
                vec![1],
                vec![],
                (2, Some(8)),
                None,
            )
        );
    }

    #[test]
    fn parks_a_call_whose_scripted_answer_is_empty() {
        let mut ledger = ledger();
        ledger.startup_heights = VecDeque::from([MockStartupHeight {
            height: None,
            failure: None,
        }]);
        ledger.take_height_call();
        assert_eq!(ledger.resolve_height(3, "site".to_string()), vec![0]);
    }

    #[test]
    fn reports_answers_no_call_claimed() {
        let mut ledger = ledger();
        ledger.resolve_height(5, "Foo_test.res:3".to_string());
        assert_eq!(
            ledger.unclaimed_answers_message().as_deref(),
            Some("Chain 1 registered these mock answers before their call arrived, and no call ever claimed them:\n  resolveGetHeightOrThrow at Foo_test.res:3")
        );
    }

    #[test]
    fn resolves_one_call_by_index_once() {
        let mut ledger = ledger();
        ledger.take_height_call();
        ledger.take_height_call();
        assert_eq!(
            (
                ledger.resolve_height_at(1),
                ledger.resolve_height_at(1),
                ledger.pending_height_indices(),
                ledger.resolve_height_at(2),
                ledger.resolve_height_at(-1),
            ),
            (
                Ok(true),
                Ok(false),
                vec![0],
                Err("The source has taken no getHeightOrThrow call at index 2".to_string()),
                Err("The source has taken no getHeightOrThrow call at index -1".to_string()),
            )
        );
    }

    #[test]
    fn refuses_a_reply_two_queries_could_take() {
        let mut ledger = ledger();
        take(&mut ledger, "0".to_string(), 0, None, 0);
        take(&mut ledger, "1".to_string(), 0, None, 0);
        let outcome = ledger.match_items_queries(&[reply("Respond")]);
        assert_eq!(
            (outcome.status.as_str(), outcome.message.as_deref()),
            (
                "error",
                Some("expectItemsQueries can reply to more than one pending query with entry #0 {reply: Respond(…)}:\n  {partitionId: \"0\", fromBlock: 0, toBlock: Unbounded, retryCount: 0}\n  {partitionId: \"1\", fromBlock: 0, toBlock: Unbounded, retryCount: 0}\nGive each query its own entry, told apart by partitionId:\n  {partitionId: \"0\", reply: …}\n  {partitionId: \"1\", reply: …}")
            )
        );
    }

    #[test]
    fn leaves_pending_every_query_an_entry_accounts_for() {
        let mut ledger = ledger();
        let a = take(&mut ledger, "0".to_string(), 1, Some(10), 0);
        let b = take(&mut ledger, "1".to_string(), 1, Some(10), 0);
        let outcome = ledger.match_items_queries(&[
            MockExpectedQuery {
                partition_id: Some("0".to_string()),
                ..reply("Respond")
            },
            reply("LeavePending"),
        ]);
        assert_eq!(
            (
                outcome.status.as_str(),
                outcome.assignment,
                outcome.left_pending
            ),
            ("matched", vec![a], vec![b])
        );
    }

    #[test]
    fn names_queries_no_entry_accounts_for() {
        let mut ledger = ledger();
        take(&mut ledger, "0".to_string(), 1, None, 0);
        take(&mut ledger, "1".to_string(), 5, None, 0);
        let outcome = ledger.match_items_queries(&[MockExpectedQuery {
            from_block: Some(1),
            ..reply("Respond")
        }]);
        assert_eq!(
            outcome.message.as_deref(),
            Some("expectItemsQueries matched every entry, but these pending queries are in none:\n  {partitionId: \"1\", fromBlock: 5, toBlock: Unbounded, retryCount: 0}\nReply to them in this list, or keep them pending:\n  {partitionId: \"1\", reply: LeavePending}")
        );
    }

    #[test]
    fn waits_with_the_reason_each_entry_is_unmatched() {
        let mut ledger = ledger();
        take(&mut ledger, "0".to_string(), 1, Some(100), 0);
        let outcome = ledger.match_items_queries(&[MockExpectedQuery {
            from_block: Some(101),
            to_block_unbounded: Some(true),
            ..reply("LeavePending")
        }]);
        assert_eq!(
            (outcome.status.as_str(), outcome.message.as_deref()),
            (
                "wait",
                Some("expectItemsQueries timed out. Expected:\n  #0 {fromBlock: 101, toBlock: Unbounded, reply: LeavePending} (matches no pending query)\nPending:\n  {partitionId: \"0\", fromBlock: 1, toBlock: Bounded(100), retryCount: 0}")
            )
        );
    }

    #[test]
    fn matches_an_address_in_any_letter_case() {
        let mut ledger = ledger();
        ledger.take_items_query(
            "0".to_string(),
            1,
            None,
            0,
            vec!["0x00000000000000000000000000000000000000aa".to_string()],
            0,
        );
        let b = ledger.take_items_query(
            "1".to_string(),
            1,
            None,
            0,
            vec!["0x00000000000000000000000000000000000000bb".to_string()],
            0,
        );
        let outcome = ledger.match_items_queries(&[
            MockExpectedQuery {
                address: Some("0x00000000000000000000000000000000000000BB".to_string()),
                ..reply("Respond")
            },
            reply("LeavePending"),
        ]);
        assert_eq!(
            (outcome.status.as_str(), outcome.assignment),
            ("matched", vec![b])
        );
    }

    #[test]
    fn hints_that_an_unmatched_entry_may_be_a_follow_up() {
        let mut ledger = ledger();
        take(&mut ledger, "0".to_string(), 1, None, 0);
        let outcome = ledger.match_items_queries(&[
            MockExpectedQuery {
                partition_id: Some("0".to_string()),
                ..reply("Respond")
            },
            MockExpectedQuery {
                partition_id: Some("1".to_string()),
                address: Some("0xAb".to_string()),
                ..reply("Respond")
            },
        ]);
        assert_eq!(
            outcome.message.as_deref(),
            Some("expectItemsQueries timed out. Expected:\n  #0 {partitionId: \"0\", reply: Respond(…)}\n  #1 {partitionId: \"1\", address: \"0xAb\", reply: Respond(…)} (matches no pending query)\nPending:\n  {partitionId: \"0\", fromBlock: 1, toBlock: Unbounded, retryCount: 0}\nThe list replies only once every entry matches, but the indexer may send a query only after an earlier one is answered. If an unmatched entry is such a follow-up, expect it in a later expectItemsQueries call.")
        );
    }

    #[test]
    fn names_the_known_height_for_an_unbounded_reply_cut_short() {
        let mut ledger = ledger();
        let id = ledger.take_items_query("0".to_string(), 101, None, 0, vec![], 300);
        assert_eq!(
            ledger
                .check_replies(&[MockItemsReply {
                    id,
                    checked: true,
                    is_failure: false,
                    latest_fetched_block_number: None,
                    item_block_numbers: vec![200],
                }])
                .as_deref(),
            Some("expectItemsQueries can't reply an item at block 200 to {partitionId: \"0\", fromBlock: 101, toBlock: Unbounded, retryCount: 0}: a source only returns items between the query's fromBlock and the latestFetchedBlockNumber it replies (101). The query is unbounded, so a reply without latestFetchedBlockNumber stops at its fromBlock. To fetch up to the height the indexer knew, reply latestFetchedBlockNumber: 300")
        );
    }

    #[test]
    fn refuses_a_reply_past_the_query_range() {
        let mut ledger = ledger();
        let id = take(&mut ledger, "0".to_string(), 1, Some(100), 0);
        let past_to_block = MockItemsReply {
            id,
            checked: true,
            is_failure: false,
            latest_fetched_block_number: Some(101),
            item_block_numbers: vec![],
        };
        let item_past_latest = MockItemsReply {
            latest_fetched_block_number: Some(50),
            item_block_numbers: vec![60],
            ..past_to_block
        };
        assert_eq!(
            (
                ledger.check_replies(&[past_to_block]).is_some(),
                ledger.check_replies(&[item_past_latest]).as_deref()
            ),
            (
                true,
                Some("expectItemsQueries can't reply an item at block 60 to {partitionId: \"0\", fromBlock: 1, toBlock: Bounded(100), retryCount: 0}: a source only returns items between the query's fromBlock and the latestFetchedBlockNumber it replies (50)")
            )
        );
    }

    #[test]
    fn matches_a_lookup_of_exactly_its_blocks() {
        let mut ledger = ledger();
        let id = ledger.take_lookup(vec![200]);
        let wrong = ledger.match_lookup(&[100]);
        let right = ledger.match_lookup(&[200]);
        assert_eq!(
            (wrong.message.as_deref(), right.status.as_str(), right.id),
            (
                Some("expectBlockHashLookup expected a lookup of [100], but the pending lookup asks for [200]"),
                "matched",
                Some(id)
            )
        );
    }

    #[test]
    fn voids_everything_in_flight() {
        let mut ledger = ledger();
        ledger.take_height_call();
        take(&mut ledger, "0".to_string(), 1, None, 0);
        ledger.take_lookup(vec![1]);
        assert_eq!(
            (ledger.drop_pending(), ledger.describe_state()),
            (
                vec![0],
                "Mock source for chain 1 at the failure:\n  pending item queries: none\n  pending block-hash lookups: none\n  height calls taken: 1".to_string()
            )
        );
    }
}
