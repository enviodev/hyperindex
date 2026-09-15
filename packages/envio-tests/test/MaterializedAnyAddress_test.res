// A table binds to its contract's configured addresses. Saying anything about
// `srcAddress` takes that binding over: `_nin: []` excludes nothing, so the
// table reads every address the event is emitted from.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: materialized-any-address
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
  # Bound to the configured address, so only UNI transfers land here.
  uni_receipts:
    from: evm.events
    where:
      contractName: ERC20
      eventName: Transfer
    select:
      id: params.to
      total:
        _sum: params.value
  # Every ERC-20 on the chain, configured or not.
  all_receipts:
    from: evm.events
    where:
      contractName: ERC20
      eventName: Transfer
      srcAddress:
        _nin: []
    select:
      id: params.to
      total:
        _sum: params.value
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;
const alice = Addresses.mockAddresses[1];
const bob = Addresses.mockAddresses[2];
const uni = "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984";
const other = Addresses.mockAddresses[5];

const transfer = (srcAddress: \`0x\${string}\`, value: bigint) => ({
  contract: "ERC20" as const,
  event: "Transfer" as const,
  srcAddress,
  params: { from: bob, to: alice, value },
});

describe("a table that says nothing about srcAddress", () => {
  it("binds to the configured addresses, while _nin: [] reads every address", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [transfer(uni, 1n), transfer(other, 10n)],
        },
      },
    });

    t.expect({
      uni: await indexer.Uni_receipts.getAll(),
      all: await indexer.All_receipts.getAll(),
    }).toEqual({
      uni: [{ id: alice, total: 1n, chainId: 1 }],
      all: [{ id: alice, total: 11n, chainId: 1 }],
    });
  });
});
`,
)
