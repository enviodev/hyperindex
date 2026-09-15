// A contract with no configured addresses has no address set to bind to, so
// binding to it would fetch nothing and leave the table silently empty. Such a
// table reads any address instead.
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
