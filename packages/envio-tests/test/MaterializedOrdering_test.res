open Vitest

// A materializer registers before any user handler, so its registration index is
// lower and the fetched log reaches it first. That ordering is what lets a
// handler read the table and see the current event's own write.
//
// Materializers share a registration with each other — one per (contract, event)
// — but never with a user handler: a handler can filter with `where` and would
// then not see every log the table needs. So an event with tables and a handler
// produces one item per registration, which is two.
let {config}: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: materialized-ordering
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  totals:
    as_entity: Totals
    from: evm.events
    select:
      id: params.to
      amount:
        _sum: params.value
  # A second table on the same event, so both writes go through one handler.
  last_seen:
    as_entity: Last_seen
    from: evm.events
    select:
      id: params.to
      sender: params.from
`,
  ~schema=`
type Note {
  id: ID!
  seen: BigInt!
  sender: String!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "ERC20", event: "Transfer" }, async ({ event, context }) => {
  // Both tables are already written for this event by the time the handler runs.
  const total = await context.Totals.get(event.params.to);
  const seen = await context.Last_seen.get(event.params.to);
  context.Note.set({
    id: event.params.to,
    seen: total?.amount ?? -1n,
    sender: seen?.sender ?? "unwritten",
  });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;
const alice = Addresses.mockAddresses[0];
const bob = Addresses.mockAddresses[1];

const transfer = (value: bigint) => ({
  contract: "ERC20" as const,
  event: "Transfer" as const,
  params: { from: bob, to: alice, value },
});

describe("materializer ordering", () => {
  it("writes the tables before the handler that reads them", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1: { simulate: [transfer(5n), transfer(7n)] } } });

    t.expect({
      totals: await indexer.Totals.getAll(),
      lastSeen: await indexer.Last_seen.getAll(),
      notes: await indexer.Note.getAll(),
    }).toEqual({
      totals: [{ id: alice, amount: 12n, chainId: 1 }],
      lastSeen: [{ id: alice, sender: bob, chainId: 1 }],
      // 12n, not 5n: the handler on the second log already sees that log's own
      // contribution, so the materializer ran first on it too — the ordering
      // holds per log, not just for the first one in the batch.
      notes: [{ id: alice, seen: 12n, sender: bob, chainId: 1 }],
    });
  });

});
`,
)

// Both tables read the same event, and one handler covers both — a materializer
// shares a registration with other materializers, never with a user handler.
describe("materializer registrations", () => {
  it("Builds one handler for every table on an event", t =>
    t.expect(
      Materialization.buildHandlers(config)->Array.map(({contractName, eventName, wildcard}) => (
        contractName,
        eventName,
        wildcard,
      )),
    ).toEqual([("ERC20", "Transfer", false)])
  )
})
