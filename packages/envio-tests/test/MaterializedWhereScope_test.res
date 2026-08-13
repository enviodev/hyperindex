// What a table's `where` is for, at each of the three scopes it can have.
//
// `contractName`/`eventName` are the only fields settled at compile time: they
// decide which events get a plan at all, and cost nothing to check. Everything
// else — params, chainId, and block/transaction context — compiles to a
// predicate the runtime evaluates per event, and a block/transaction field a
// `where` reads is added to that event's `field_selection` so it is there to
// read.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: where-scope
disable_default_cross_chain: true
contracts:
  - name: ERC20
    events:
      - event: "Approval(address indexed owner, address indexed spender, uint256 value)"
      - event: "Transfer(address indexed from, address indexed to, uint256 value)"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984"
tables:
  # No \`where\` at all: a plan for every configured event, so \`select\` may only
  # read what every event has. \`params\` differ between the two, so this counts
  # events per block instead.
  block_activity:
    from: evm.events
    select:
      id: block.number
      events:
        _sum: 1

  # The usual shape: discriminators only, settled at compile time. The Approval
  # event never gets a plan, which is what lets \`params.to\` resolve here.
  transfers:
    from: evm.events
    where:
      contractName: ERC20
      eventName: Transfer
    select:
      id: params.to
      received:
        _sum: params.value

  # Context beyond the event itself. \`block.number\` and \`transaction.gasPrice\`
  # can't narrow the fetch, so both are checked per event — and \`gasPrice\` has
  # to be fetched for that check to be possible at all.
  late_cheap_transfers:
    from: evm.events
    where:
      eventName: Transfer
      block:
        number:
          _gte: 3
      transaction:
        gasPrice:
          _lte: 100
    select:
      id:
        _concat:
          separator: "/"
          values:
            - block.number
            - params.to
      value: params.value
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, TestHelpers } from "envio";

const { Addresses } = TestHelpers;
const alice = Addresses.mockAddresses[0];
const bob = Addresses.mockAddresses[1];

const transfer = (block: number, gasPrice: bigint, value: bigint) => ({
  contract: "ERC20" as const,
  event: "Transfer" as const,
  block: { number: block },
  transaction: { gasPrice },
  params: { from: bob, to: alice, value },
});

// No \`transaction.gasPrice\` here: demand is per event, and only Transfer's
// plans read it, so the generated types don't offer it on Approval.
const approval = (block: number) => ({
  contract: "ERC20" as const,
  event: "Approval" as const,
  block: { number: block },
  params: { owner: alice, spender: bob, value: 1n },
});

describe("the scope of a table's where", () => {
  it("spans every event without a where, one event with discriminators, and filters context at runtime", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            approval(2),
            transfer(2, 5n, 10n), // too early for late_cheap_transfers
            transfer(4, 5n, 20n), // kept
            transfer(4, 900n, 40n), // too expensive
          ],
        },
      },
    });

    t.expect({
      // Both events feed this one, so block 2 counts the approval too.
      blockActivity: await indexer.Block_activity.getAll(),
      // Approval never reaches this one, so every transfer is summed.
      transfers: await indexer.Transfers.getAll(),
      // Only the transfer that cleared both context conditions.
      lateCheap: await indexer.Late_cheap_transfers.getAll(),
    }).toEqual({
      blockActivity: [
        { id: 2, events: 2, chainId: 1 },
        { id: 4, events: 2, chainId: 1 },
      ],
      transfers: [{ id: alice, received: 70n, chainId: 1 }],
      lateCheap: [{ id: \`4/\${alice}\`, value: 20n, chainId: 1 }],
    });
  });
});
`,
)
