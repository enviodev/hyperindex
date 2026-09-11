// One log routed to two registrations runs two handlers but is still one
// processed event — the count is of logs, not of handler runs.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: events-processed-dedup
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
`,
  ~schema=`
type Account {
  id: ID!
  balance: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Account.set({ id: event.params.to, balance: event.params.value });
});

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  context.Account.set({ id: event.params.from, balance: event.params.value });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

const [from, to, other] = Addresses.mockAddresses;

const transfer = (params: { from: typeof from; to: typeof to; value: bigint }) => ({
  contract: "Token" as const,
  event: "Transfer" as const,
  params,
});

describe("events processed dedup", () => {
  it("counts a log once when two registrations route it", async (t) => {
    const indexer = createTestIndexer();
    const result = await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 100,
          simulate: [transfer({ from, to, value: 5n })],
        },
      },
    });

    t.expect(result.changes).toEqual([
      {
        block: 1,
        chainId: 1,
        eventsProcessed: 1,
        Account: {
          sets: [
            { id: to, balance: 5n },
            { id: from, balance: 5n },
          ],
        },
      },
    ]);
  });

  it("counts every log of a block once", async (t) => {
    const indexer = createTestIndexer();
    const result = await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 100,
          simulate: [
            transfer({ from, to, value: 5n }),
            transfer({ from, to: other, value: 7n }),
          ],
        },
      },
    });

    t.expect(result.changes.map((change) => change.eventsProcessed)).toEqual([2]);
  });
});
`,
)
