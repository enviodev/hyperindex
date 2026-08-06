// schema.graphql is optional whether or not the config declares `tables`: an
// indexer whose handlers only call effects, log, or register contracts has no
// entities to declare, and shouldn't have to ship an empty file to say so.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: no-schema
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
`,
  ~handlers=`
import { indexer } from "envio";

// The handler and test modules are separate files, so what the handler observed
// rides on the global rather than an import between them.
declare global {
  var transferred: bigint[];
}
globalThis.transferred = [];

indexer.onEvent({ contract: "ERC20", event: "Transfer" }, async ({ event, context }) => {
  // The preload pass runs the handler too, so a side effect on the global has to
  // skip it the way any non-entity side effect would.
  if (context.isPreload) return;
  globalThis.transferred.push(event.params.value);
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

declare global {
  var transferred: bigint[];
}

describe("an indexer with no entities", () => {
  it("runs handlers without a schema", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "ERC20",
              event: "Transfer",
              params: {
                from: Addresses.defaultAddress,
                to: Addresses.mockAddresses[0],
                value: 21n,
              },
            },
          ],
        },
      },
    });

    t.expect(globalThis.transferred).toEqual([21n]);
  });
});
`,
)
