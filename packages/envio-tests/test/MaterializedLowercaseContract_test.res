// The runtime capitalizes contract names (`myToken` in config.yaml is `MyToken`
// in the chain config), so the write plans must carry the capitalized name or
// the materializer's registration matches nothing and startup throws.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: lowercase-contract
disable_default_cross_chain: true
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
tables:
  transfers:
    from: evm.events
    where:
      contractName: myToken
      eventName: Transfer
    select:
      id: params.to
      total:
        _sum: params.value
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;
const alice = Addresses.mockAddresses[0];

describe("Materialized table on a lowercase-named contract", () => {
  it("routes the event to the materializer", async (t) => {
    const indexer = createTestIndexer();

    // The runtime routes by the capitalized contract name, but the generated
    // simulate types still spell the raw yaml name — a pre-existing mismatch
    // for lowercase-named contracts, so this casts past the type.
    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "MyToken",
              event: "Transfer",
              params: { from: Addresses.defaultAddress, to: alice, value: 4n },
            } as never,
          ],
        },
      },
    });

    t.expect(await indexer.Transfers.getAll()).toEqual([{ id: alice, total: 4n, chainId: 1 }]);
  });
});
`,
)
