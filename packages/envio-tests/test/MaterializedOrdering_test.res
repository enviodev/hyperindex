open Vitest

// Materializers share a registration with each other — one per (contract,
// event) — but never with a user handler: a handler can filter with `where` and
// would then not see every log the table needs. So an event with tables and a
// handler produces one item per registration, which is two.
//
// Two tables on one event therefore run in order within that shared handler,
// which is what lets a later table see an earlier one's contribution.
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
    from: evm.events
    select:
      id: params.to
      amount:
        _sum: params.value
  # A second table on the same event, so both writes go through one handler.
  last_seen:
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
  context.Note.set({ id: event.params.to, seen: event.params.value, sender: event.params.from });
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
  it("runs a handler alongside the tables on one event", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({ chains: { 1: { simulate: [transfer(5n), transfer(7n)] } } });

    // The tables themselves are read back in MaterializedWrites_test; what
    // this run pins is that a handler on the same event still runs.
    t.expect(await indexer.Note.getAll()).toEqual([
      { id: alice, seen: 7n, sender: bob, chainId: 1 },
    ]);
  });


  it("counts the log once per registration", async (t) => {
    const indexer = createTestIndexer();

    const result = await indexer.process({ chains: { 1: { simulate: [transfer(5n)] } } });

    // One log, two registrations: the shared materializer's and the handler's.
    t.expect(result.changes.map((c) => c.eventsProcessed)).toEqual([2]);
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
