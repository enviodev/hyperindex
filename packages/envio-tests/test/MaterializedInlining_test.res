// A materialized table shares an event with a handler here. The materializer
// runs inside that handler's registration rather than taking one of its own, so
// the log is fetched and counted once — `eventsProcessed` is the observable, and
// the handler still reads the current event's contribution.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: materialized-inlining
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Approval(address indexed owner, address indexed spender, uint256 value)"
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
    where:
      eventName: Transfer
    select:
      id: params.to
      amount:
        _sum: params.value
  # Nothing handles Approval, so this one keeps a registration of its own.
  approvers:
    from: evm.events
    where:
      eventName: Approval
    select:
      id: params.owner
      amount: params.value
`,
  ~schema=`
type Note {
  id: ID!
  seen: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "ERC20", event: "Transfer" }, async ({ event, context }) => {
  const total = await context.Totals.get(event.params.to);
  context.Note.set({ id: event.params.to, seen: total?.amount ?? -1n });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;
const alice = Addresses.mockAddresses[0];

describe("materializer sharing a handler's registration", () => {
  it("counts the log once and still writes both tables", async (t) => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "ERC20",
              event: "Transfer",
              params: { from: Addresses.defaultAddress, to: alice, value: 5n },
            },
          ],
        },
      },
    });

    t.expect({
      // One log, one event — not one per registration.
      eventsProcessed: result.changes.map((c) => c.eventsProcessed),
      totals: await indexer.Totals.getAll(),
      // The handler saw this event's own contribution, so the materializer ran
      // first inside the shared registration.
      notes: await indexer.Note.getAll(),
    }).toEqual({
      eventsProcessed: [1],
      totals: [{ id: alice, amount: 5n, chainId: 1 }],
      notes: [{ id: alice, seen: 5n, chainId: 1 }],
    });
  });

  it("keeps a registration of its own when no handler shares the event", async (t) => {
    const indexer = createTestIndexer();

    const result = await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "ERC20",
              event: "Approval",
              params: { owner: alice, spender: Addresses.defaultAddress, value: 9n },
            },
          ],
        },
      },
    });

    t.expect({
      eventsProcessed: result.changes.map((c) => c.eventsProcessed),
      approvers: await indexer.Approvers.getAll(),
    }).toEqual({
      eventsProcessed: [1],
      approvers: [{ id: alice, amount: 9n, chainId: 1 }],
    });
  });
});
`,
)
