// The runtime keys contracts by their capitalized name (Config.res builds every
// chain's contracts under `capitalizedName`), so the generated `contract:`
// literals have to agree — otherwise a config that spells a contract
// `myToken` produces handler registrations and simulate items the runtime can
// never match.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: lowercase-contract
contracts:
  - name: myToken
    events:
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: myToken
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
`,
  ~schema=`
type Received {
  id: ID!
  total: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "MyToken", event: "Transfer" }, async ({ event, context }) => {
  const existing = await context.Received.get(event.params.to);
  context.Received.set({
    id: event.params.to,
    total: (existing?.total ?? 0n) + event.params.value,
  });
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;
const alice = Addresses.mockAddresses[0];

describe("a contract whose config name is not capitalized", () => {
  it("registers a handler and routes a simulated event to it", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "MyToken",
              event: "Transfer",
              params: { from: Addresses.defaultAddress, to: alice, value: 4n },
            },
          ],
        },
      },
    });

    t.expect(await indexer.Received.getAll()).toEqual([{ id: alice, total: 4n }]);
  });
});
`,
)
