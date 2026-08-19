// A table may be named with leading underscores — useful for keeping a
// derived table out of the way alphabetically — while generated code reaches
// it by a name it can actually spell: capitalized, underscores dropped.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: underscore-table
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
  _totals:
    as_entity: Total
    from: evm.events
    select:
      id: params.to
      received:
        _sum: params.value
  _senders:
    from: evm.events
    select:
      id: params.from
      sent:
        _sum: params.value
`,
  ~handlers=`
import { indexer } from "envio";

declare global {
  var totals: (bigint | undefined)[];
}
globalThis.totals = [];

indexer.onEvent({ contract: "ERC20", event: "Transfer" }, async ({ event, context }) => {
  if (context.isPreload) return;
  // The database and GraphQL name is \`_totals\`; handlers use \`as_entity\`.
  globalThis.totals.push((await context.Total.get(event.params.to))?.received);
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;
const alice = Addresses.mockAddresses[0];

declare global {
  var totals: (bigint | undefined)[];
}

describe("a table named with leading underscores", () => {
  it("is reached by its name capitalized and stripped of underscores", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "ERC20",
              event: "Transfer",
              params: { from: Addresses.defaultAddress, to: alice, value: 6n },
            },
          ],
        },
      },
    });

    t.expect({
      // \`as_entity\` names this one; \`_senders\` falls back to the derived name.
      totals: await indexer.Total.getAll(),
      senders: await indexer.Senders.getAll(),
      seenByHandler: globalThis.totals,
    }).toEqual({
      totals: [{ id: alice, received: 6n, chainId: 1 }],
      senders: [{ id: Addresses.defaultAddress, sent: 6n, chainId: 1 }],
      seenByHandler: [6n],
    });
  });
});
`,
)
