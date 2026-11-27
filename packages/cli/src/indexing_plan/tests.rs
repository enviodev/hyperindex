use super::chain::{Addresses, BlockRegistration, ChainConfig, ChainPlan, EventRegistration, What};
use super::coverage::Coverage;
use super::pipeline::{Planned, Tick};
use crate::address_store::test_support::evm_store;
use crate::address_store::{AddressRegistration, AddressStore};
use crate::chain_buffer::page::Page;
use crate::chain_buffer::{ChainBuffer, ChainBufferConfig, RegistrationsInput};

const PAIR1: &str = "0x1000000000000000000000000000000000000001";
const PAIR2: &str = "0x1000000000000000000000000000000000000002";
const PAIR3: &str = "0x1000000000000000000000000000000000000003";

fn buffer(store: &AddressStore) -> ChainBuffer {
    ChainBuffer::make(
        ChainBufferConfig {
            registrations: RegistrationsInput::Evm {
                registrations: vec![],
            },
            should_checksum: false,
            contract_register_indexes: vec![],
            block_handlers: vec![],
            transaction_masks: vec![],
            event_block_masks: vec![],
            transaction_registrations: vec![],
        },
        store,
    )
    .unwrap()
}

/// A Factory with one address-free event and a Pair fetched by address.
fn chain(pairs: &[&str], configure: impl FnOnce(&mut ChainConfig)) -> ChainPlan {
    let store = evm_store(&[("Factory", &[]), ("Pair", pairs)]);
    let mut config = ChainConfig {
        chain_id: 1,
        start_block: 1,
        end_block: None,
        block_lag: 0,
        block_throttle: 0,
        known_height: 1000,
        progress_block_number: 0,
        max_reorg_depth: 0,
        should_rollback_on_reorg: false,
        max_group_size: 5000,
        address_free_threshold: None,
        has_generated_block_handlers: false,
        blocks_apart: false,
        events: vec![
            EventRegistration {
                index: 0,
                contract: 0,
                depends_on_addresses: false,
                start_block: None,
            },
            EventRegistration {
                index: 1,
                contract: 1,
                depends_on_addresses: true,
                start_block: None,
            },
        ],
        blocks: vec![],
        transactions: vec![],
        contract_end_blocks: vec![None, None],
        is_resumed: false,
    };
    configure(&mut config);
    let buffer = buffer(&store);
    ChainPlan::new(config, store.handle(), buffer)
        .map(|(plan, _)| plan)
        .unwrap()
}

fn tick(target_block: i64) -> Tick {
    Tick {
        target_block,
        target_items: 1_000_000.,
        chain_density: None,
        processing_block: 0,
    }
}

/// A started request: slot, generation, needs, from, to.
type Started = (u32, u32, Vec<u32>, i64, Option<i64>);

fn start(plan: &mut ChainPlan, target_block: i64) -> Vec<Started> {
    match plan.plan_requests(&tick(target_block)) {
        Planned::Start(started) => started
            .into_iter()
            .map(|(slot, generation)| {
                let request = plan.requests.slots[slot as usize].as_ref().unwrap();
                (
                    slot,
                    generation,
                    request.needs.clone(),
                    request.from_block,
                    request.to_block,
                )
            })
            .collect(),
        _ => Vec::new(),
    }
}

fn complete(plan: &mut ChainPlan, slot: u32, generation: u32, latest: i64) {
    let page = Page::empty("evm".to_string()).unwrap();
    let (completion, _) = plan.complete(slot, generation, &page, latest, 0, plan.known_height);
    assert!(completion.is_some(), "the request was still out");
}

fn register(plan: &mut ChainPlan, address: &str, block: i64) {
    plan.register(vec![AddressRegistration {
        address: address.to_string(),
        contract_name: "Pair".to_string(),
        registration_block: block,
    }])
    .unwrap();
}

fn addresses_of(plan: &ChainPlan, need: u32) -> Vec<String> {
    let store = plan.store.read().unwrap();
    let ids = match &plan.needs.what[need as usize] {
        What::Logs {
            addresses: Addresses::Group(group),
            ..
        } => plan.groups.ids[*group as usize].clone(),
        What::Logs {
            addresses: Addresses::List(ids),
            ..
        } => ids.clone(),
        _ => Vec::new(),
    };
    drop(store);
    crate::address_store::AddressSet::new(plan.store.clone(), ids).addresses()
}

#[test]
fn starts_with_an_address_free_need_and_a_group() {
    let mut plan = chain(&[PAIR1], |_| {});
    assert_eq!(
        (
            start(&mut plan, 1000)
                .into_iter()
                .map(|(_, _, needs, from, to)| (needs, from, to))
                .collect::<Vec<_>>(),
            addresses_of(&plan, 1),
            plan.ready_through_block(),
        ),
        (
            vec![(vec![0], 1, None), (vec![1], 1, None)],
            vec![PAIR1.to_string()],
            0,
        )
    );
}

#[test]
fn covers_what_the_source_reached_and_asks_for_the_rest_again() {
    let mut plan = chain(&[PAIR1], |_| {});
    let started = start(&mut plan, 1000);
    let (slot, generation, ..) = started[1];
    complete(&mut plan, slot, generation, 300);
    let next = start(&mut plan, 1000);
    assert_eq!(
        (
            plan.needs.coverage[1].clone(),
            next.into_iter()
                .map(|(_, _, needs, from, to)| (needs, from, to))
                .collect::<Vec<_>>()
        ),
        (Coverage::new(300), vec![(vec![1], 301, None)])
    );
}

#[test]
fn a_registered_address_waits_for_the_open_request_then_owes_a_bounded_catch_up() {
    let mut plan = chain(&[PAIR1], |_| {});
    let started = start(&mut plan, 1000);
    let (slot, generation, ..) = started[1];
    complete(&mut plan, slot, generation, 300);
    let open = start(&mut plan, 1000);
    let (open_slot, open_generation, ..) = open[0];

    register(&mut plan, PAIR2, 10);
    let held = plan.ready_through_block();
    complete(&mut plan, open_slot, open_generation, 400);
    let catch_up = plan.needs.len() - 1;

    assert_eq!(
        (
            held,
            addresses_of(&plan, 1),
            addresses_of(&plan, catch_up),
            plan.needs.floor[catch_up as usize],
            plan.needs.to_block[catch_up as usize],
            plan.needs.joins[catch_up as usize],
        ),
        (
            0,
            vec![PAIR1.to_string(), PAIR2.to_string()],
            vec![PAIR2.to_string()],
            9,
            Some(400),
            Some(1),
        )
    );
}

#[test]
fn an_address_registered_above_what_was_asked_joins_without_a_catch_up() {
    let mut plan = chain(&[PAIR1], |_| {});
    let started = start(&mut plan, 1000);
    let (slot, generation, ..) = started[1];
    complete(&mut plan, slot, generation, 300);
    register(&mut plan, PAIR2, 500);
    assert_eq!(
        (plan.needs.len(), addresses_of(&plan, 1)),
        (2, vec![PAIR1.to_string(), PAIR2.to_string()])
    );
}

#[test]
fn an_address_of_a_contract_with_only_full_groups_starts_a_group_of_its_own() {
    let mut plan = chain(&[PAIR1], |config| config.max_group_size = 1);
    let started = start(&mut plan, 1000);
    let (slot, generation, ..) = started[1];
    complete(&mut plan, slot, generation, 300);
    register(&mut plan, PAIR2, 10);
    let group_need = plan.groups.need[1];
    assert_eq!(
        (
            plan.needs.len(),
            addresses_of(&plan, group_need),
            plan.needs.coverage[group_need as usize].covered_through,
        ),
        (3, vec![PAIR2.to_string()], 9)
    );
}

#[test]
fn addresses_past_a_group_s_room_start_a_group_at_the_block_it_was_asked_through() {
    let mut plan = chain(&[PAIR1], |config| config.max_group_size = 2);
    let started = start(&mut plan, 1000);
    let (slot, generation, ..) = started[1];
    complete(&mut plan, slot, generation, 300);
    plan.register(
        [PAIR2, PAIR3]
            .iter()
            .map(|address| AddressRegistration {
                address: address.to_string(),
                contract_name: "Pair".to_string(),
                registration_block: 10,
            })
            .collect(),
    )
    .unwrap();
    let overflow_group = plan.groups.need[1];
    let lists: Vec<(Vec<String>, Option<i64>)> = (0..plan.needs.len())
        .filter(|&need| plan.needs.is_list(need))
        .map(|need| {
            (
                addresses_of(&plan, need),
                plan.needs.to_block[need as usize],
            )
        })
        .collect();
    assert_eq!(
        (
            addresses_of(&plan, 1),
            plan.groups.sealed[0],
            addresses_of(&plan, overflow_group),
            plan.needs.coverage[overflow_group as usize].covered_through,
            lists,
        ),
        (
            vec![PAIR1.to_string(), PAIR2.to_string()],
            true,
            vec![PAIR3.to_string()],
            300,
            vec![
                (vec![PAIR2.to_string()], Some(300)),
                (vec![PAIR3.to_string()], Some(300))
            ],
        )
    );
}

#[test]
fn a_rollback_clips_coverage_drops_requests_and_prunes_addresses() {
    let mut plan = chain(&[PAIR1], |_| {});
    let started = start(&mut plan, 1000);
    let (slot, generation, ..) = started[1];
    complete(&mut plan, slot, generation, 300);
    register(&mut plan, PAIR2, 250);
    let catch_up = plan.needs.len() - 1;
    let out = start(&mut plan, 1000);
    plan.rollback(200);
    let (late_slot, late_generation, ..) = out[0];
    let page = Page::empty("evm".to_string()).unwrap();
    let (late, _) = plan.complete(late_slot, late_generation, &page, 900, 0, 1000);
    assert_eq!(
        (
            late.is_none(),
            plan.needs.coverage[1].clone(),
            addresses_of(&plan, 1),
            plan.needs.live[catch_up as usize],
        ),
        (true, Coverage::new(200), vec![PAIR1.to_string()], false)
    );
}

#[test]
fn at_the_head_one_request_carries_every_need() {
    let mut plan = chain(&[PAIR1], |config| {
        config.blocks = vec![BlockRegistration {
            index: 0,
            start_block: None,
        }];
    });
    for (slot, generation, ..) in start(&mut plan, 1000) {
        complete(&mut plan, slot, generation, 1000);
    }
    plan.set_known_height(1001);
    let first = start(&mut plan, 1001);
    let (slot, generation, ..) = first[0];
    complete(&mut plan, slot, generation, 1001);
    plan.set_known_height(1002);
    let second = start(&mut plan, 1002);
    assert_eq!(
        (
            plan.head_mode,
            first
                .into_iter()
                .map(|(_, _, needs, from, _)| (needs, from))
                .collect::<Vec<_>>(),
            second
                .into_iter()
                .map(|(_, _, needs, from, _)| (needs, from))
                .collect::<Vec<_>>(),
        ),
        (
            true,
            vec![(vec![0, 1, 2], 1001)],
            vec![(vec![0, 1, 2], 1002)]
        )
    );
}

#[test]
fn a_contract_going_address_free_at_the_head_ends_its_group_and_owes_a_catch_up() {
    let mut plan = chain(&[PAIR1], |_| {});
    for (slot, generation, ..) in start(&mut plan, 1000) {
        complete(&mut plan, slot, generation, 1000);
    }
    plan.set_known_height(1001);
    let out = start(&mut plan, 1001);
    let free_contracts_before = plan.needs.len();
    plan.register(vec![AddressRegistration {
        address: PAIR2.to_string(),
        contract_name: "Pair".to_string(),
        registration_block: 990,
    }])
    .unwrap();
    let new_needs: Vec<(bool, i64, Option<i64>)> = (free_contracts_before..plan.needs.len())
        .map(|need| {
            (
                plan.needs.is_list(need),
                plan.needs.coverage[need as usize].covered_through,
                plan.needs.to_block[need as usize],
            )
        })
        .collect();
    assert_eq!(
        (out.len(), plan.head_mode, new_needs),
        (1, true, vec![(false, 1001, None), (true, 989, Some(1001))])
    );
}

/// A factory registering an address every block at the head leaves one
/// catch-up per registration; once a catch-up is done and below the reorg
/// window, its slot is reused, so the needs stay as many as the window holds.
#[test]
fn finished_catch_ups_below_the_reorg_window_are_reclaimed() {
    let mut plan = chain(&[PAIR1], |config| {
        config.max_reorg_depth = 10;
        config.should_rollback_on_reorg = true;
    });
    for (slot, generation, ..) in start(&mut plan, 1000) {
        complete(&mut plan, slot, generation, 1000);
    }
    for height in 1001..1201 {
        plan.set_known_height(height);
        let address = format!("0x2{:039x}", height);
        register(&mut plan, &address, height - 1);
        for _ in 0..3 {
            for (slot, generation, ..) in start(&mut plan, height) {
                complete(&mut plan, slot, generation, height);
            }
        }
    }
    assert!(plan.needs.len() < 30, "needs: {}", plan.needs.len());
}
