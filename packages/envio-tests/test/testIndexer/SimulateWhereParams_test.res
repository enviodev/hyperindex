// A simulated item reaches only the registrations whose static `where.params`
// match its indexed params, the way a real source selects logs by topic.
let alice = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
let bob = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
let carol = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: simulate-where-params
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 amount)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
`,
  ~schema=`
type Seen {
  id: ID!
  amount: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent(
  { contract: "Token", event: "Transfer", where: { params: { from: "${alice}" } } },
  async ({ event, context }) => {
    context.Seen.set({ id: "from-alice-" + event.params.amount, amount: event.params.amount });
  },
);
indexer.onEvent(
  { contract: "Token", event: "Transfer", where: { params: [{ from: "${bob}" }, { to: "${bob}" }] } },
  async ({ event, context }) => {
    context.Seen.set({ id: "bob-" + event.params.amount, amount: event.params.amount });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const transfer = (from: \`0x\${string}\`, to: \`0x\${string}\`, amount: bigint) =>
  ({ contract: "Token", event: "Transfer", params: { from, to, amount } }) as const;

describe("simulate with where params", () => {
  it("runs only the handlers whose filter matches the item", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 10,
          simulate: [
            transfer("${alice}", "${carol}", 1n),
            transfer("${bob}", "${carol}", 2n),
            transfer("${alice}", "${bob}", 3n),
          ],
        },
      },
    });

    t.expect(
      (await indexer.Seen.getAll()).toSorted((a, b) => a.id.localeCompare(b.id)),
    ).toEqual([
      { id: "bob-2", amount: 2n },
      { id: "bob-3", amount: 3n },
      { id: "from-alice-1", amount: 1n },
      { id: "from-alice-3", amount: 3n },
    ]);
  });

  it("reports an item no filter matches as unrouted", async (t) => {
    const indexer = createTestIndexer();
    const error = await indexer
      .process({
        chains: { 1: { startBlock: 1, endBlock: 10, simulate: [transfer("${carol}", "${carol}", 4n)] } },
      })
      .then(() => "no error", (error: Error) => error.message);

    t.expect(error).toContain("never reached a handler");
  });
});
`,
)
