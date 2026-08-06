// A contract with no configured addresses is only reachable through a wildcard
// registration. The materializer's own registration is address-bound, so
// without `wildcard: true` on the table it would fetch nothing and the table
// would sit silently empty.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: materialized-wildcard
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
tables:
  receipts:
    from: evm.events
    wildcard: true
    where:
      contractName: ERC20
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

describe("a wildcard materialized table", () => {
  it("materializes an event from a contract with no configured address", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "ERC20",
              event: "Transfer",
              srcAddress: Addresses.mockAddresses[3],
              params: { from: Addresses.defaultAddress, to: alice, value: 6n },
            },
          ],
        },
      },
    });

    t.expect(await indexer.Receipts.getAll()).toEqual([{ id: alice, total: 6n, chainId: 1 }]);
  });
});
`,
)
