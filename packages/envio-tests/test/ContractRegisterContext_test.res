// One contract register context serves every register run of a fetch response,
// so each run must still find its own item: the chain it registers on, and a
// resolved run refusing an `add` it kept.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: contract-register-context
contracts:
  - name: Factory
    events:
      - event: PoolCreated(address pool)
  - name: Pool
    events:
      - event: Swap(uint256 amount)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Factory
        address: "0x1111111111111111111111111111111111111111"
      - name: Pool
  - id: 10
    start_block: 0
    contracts:
      - name: Factory
        address: "0x2222222222222222222222222222222222222222"
      - name: Pool
`,
  ~schema=`
type Swap {
  id: ID!
  amount: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

const state = globalThis as unknown as { seenChainIds: number[]; lateErrors: string[] };
state.seenChainIds = [];
state.lateErrors = [];

indexer.contractRegister(
  { contract: "Factory", event: "PoolCreated" },
  async ({ event, context }) => {
    state.seenChainIds.push(context.chain.id);
    const add = context.chain.Pool.add;
    add(event.params.pool);
    setTimeout(() => {
      try {
        add(event.params.pool);
      } catch (error) {
        state.lateErrors.push((error as Error).message);
      }
    }, 0);
  },
);

indexer.onEvent({ contract: "Pool", event: "Swap" }, async ({ event, context }) => {
  context.Swap.set({ id: \`\${event.chainId}\`, amount: event.params.amount });
});
`,
  ~test=`
import { it } from "vitest";
import { createTestIndexer } from "envio";

const state = globalThis as unknown as { seenChainIds: number[]; lateErrors: string[] };
const pool1 = "0x3333333333333333333333333333333333333333";
const pool2 = "0x4444444444444444444444444444444444444444";

it("registers on each chain from one context, and refuses a late add", async (t) => {
  const indexer = createTestIndexer();

  await indexer.process({
    chains: {
      1: {
        simulate: [
          { contract: "Factory", event: "PoolCreated", block: { number: 1 }, params: { pool: pool1 } },
          { contract: "Pool", event: "Swap", block: { number: 2 }, srcAddress: pool1, params: { amount: 1n } },
        ],
      },
      10: {
        simulate: [
          { contract: "Factory", event: "PoolCreated", block: { number: 1 }, params: { pool: pool2 } },
          { contract: "Pool", event: "Swap", block: { number: 2 }, srcAddress: pool2, params: { amount: 2n } },
        ],
      },
    },
  });
  await new Promise((resolve) => setTimeout(resolve, 10));

  t.expect({
    seenChainIds: [...state.seenChainIds].sort(),
    pools: { 1: indexer.chains[1].Pool.addresses, 10: indexer.chains[10].Pool.addresses },
    swaps: await indexer.Swap.getAll(),
    lateErrors: state.lateErrors,
  }).toEqual({
    seenChainIds: [1, 10],
    pools: { 1: [pool1], 10: [pool2] },
    swaps: [
      { id: "1", amount: 1n },
      { id: "10", amount: 2n },
    ],
    lateErrors: [
      "Impossible to access context.chain after the contract register is resolved. Make sure you didn't miss an await in the handler.",
      "Impossible to access context.chain after the contract register is resolved. Make sure you didn't miss an await in the handler.",
    ],
  });
});
`,
)
