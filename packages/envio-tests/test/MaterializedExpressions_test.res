// The expression and filter kinds the ERC-20 config doesn't reach: `_literal`,
// `_concat` over mixed types, and a `where` that survives compilation as a
// runtime predicate.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: materialized-expressions
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
  # Only large transfers, and only from block 3 on: \`contractName\`/\`eventName\`
  # bind the table to the event at compile time, and the rest is checked per
  # event at runtime.
  large_transfers:
    from: evm.events
    where:
      _and:
        - contractName: ERC20
          eventName: Transfer
        - params:
            value:
              _gte: 100
        - _or:
            - block:
                number:
                  _gte: 3
            - chainId: 999
    select:
      id:
        _concat:
          separator: "/"
          values:
            - chainId
            - params.to
            - params.value
      kind:
        _literal: large
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;
const alice = Addresses.mockAddresses[0];

const transfer = (block: number, value: bigint) => ({
  contract: "ERC20" as const,
  event: "Transfer" as const,
  block: { number: block },
  params: { from: Addresses.defaultAddress, to: alice, value },
});

describe("Materialized expressions", () => {
  it("keeps only the rows the runtime filter admits", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            transfer(3, 50n), // below the amount threshold
            transfer(1, 500n), // below the block threshold
            transfer(4, 250n), // kept
          ],
        },
      },
    });

    t.expect(await indexer.Large_transfers.getAll()).toEqual([
      {
        // \`_concat\` renders an Int, an address and a BigInt canonically.
        id: \`1/\${alice}/250\`,
        kind: "large",
        chainId: 1,
      },
    ]);
  });
});
`,
)
