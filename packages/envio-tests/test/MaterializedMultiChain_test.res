// Two tables fed by one event, and the per-chain keying `tables` insists on.
// Neither needs the indexer loop: `simulate` drives the real registrations, so
// the materializer handlers run exactly as they would against a live chain.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: materialized-multi
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
  - id: 137
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  totals:
    from: evm.events
    select:
      id: params.to
      amount:
        _sum: params.value
  # Same event, a second table: one handler runs both writes.
  last_seen:
    from: evm.events
    select:
      id: params.to
      block: block.number
  # One row for every chain, so both chains' transfers add up in it.
  shared_totals:
    cross_chain: true
    from: evm.events
    select:
      id: params.to
      amount:
        _sum: params.value
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;
const alice = Addresses.mockAddresses[0];

const transfer = (value: bigint, blockNumber: number) => ({
  contract: "ERC20" as const,
  event: "Transfer" as const,
  params: { from: Addresses.defaultAddress, to: alice, value },
  block: { number: blockNumber },
});

describe("one event, several tables, several chains", () => {
  it("writes every table the event feeds, keyed per chain unless shared", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [transfer(3n, 10), transfer(4n, 11)] },
        137: { simulate: [transfer(40n, 12)] },
      },
    });

    t.expect({
      totals: await indexer.Totals.getAll(),
      lastSeen: await indexer.Last_seen.getAll(),
      shared: await indexer.Shared_totals.getAll(),
    }).toEqual({
      totals: [
        { id: alice, amount: 7n, chainId: 1 },
        { id: alice, amount: 40n, chainId: 137 },
      ],
      lastSeen: [
        { id: alice, block: 11, chainId: 1 },
        { id: alice, block: 12, chainId: 137 },
      ],
      shared: [{ id: alice, amount: 47n }],
    });
  });
});
`,
)
