// A simulated item matching one `where` alternative is kept even when another
// alternative filters by `chain.<Contract>.addresses`, the way a real source
// selects logs by topic per alternative.
let alice = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
let bob = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
let carol = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
let token = "0x1111111111111111111111111111111111111111"
let vat = "0x2222222222222222222222222222222222222222"
let fileSig = "0x29ae8114"
let slipSig = "0x7cdd3fde"

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: simulate-where-addresses
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 amount)
  - name: Vat
    events:
      - event: LogNote(bytes4 indexed sig, address indexed guy, uint256 wad) anonymous
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "${token}"
      - name: Vat
        address: "${vat}"
`,
  ~schema=`
type Seen {
  id: ID!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent(
  {
    contract: "Token",
    event: "Transfer",
    where: ({ chain }) => ({ params: [{ from: "${alice}" }, { to: chain.Token.addresses }] }),
  },
  async ({ event, context }) => {
    context.Seen.set({ id: "transfer-" + event.params.amount });
  },
);
indexer.onEvent(
  {
    contract: "Vat",
    event: "LogNote",
    where: ({ chain }) => ({
      params: [{ sig: "${fileSig}" }, { sig: "${slipSig}", guy: chain.Vat.addresses }],
    }),
  },
  async ({ event, context }) => {
    context.Seen.set({ id: "note-" + event.params.wad });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const transfer = (from: \`0x\${string}\`, to: \`0x\${string}\`, amount: bigint) =>
  ({ contract: "Token", event: "Transfer", srcAddress: "${token}", params: { from, to, amount } }) as const;
const note = (sig: \`0x\${string}\`, guy: \`0x\${string}\`, wad: bigint) =>
  ({ contract: "Vat", event: "LogNote", srcAddress: "${vat}", params: { sig, guy, wad } }) as const;

describe("simulate with where params filtering by contract addresses", () => {
  it("keeps an item that matches an alternative without the address filter", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 1,
          endBlock: 10,
          simulate: [
            transfer("${alice}", "${carol}", 1n),
            transfer("${bob}", "${token}", 2n),
            note("${fileSig}", "${carol}", 3n),
            note("${slipSig}", "${vat}", 4n),
          ],
        },
      },
    });

    t.expect(
      (await indexer.Seen.getAll()).map((seen) => seen.id).toSorted(),
    ).toEqual(["note-3", "note-4", "transfer-1", "transfer-2"]);
  });

  it("drops an item whose param isn't a registered address of the contract", async (t) => {
    const indexer = createTestIndexer();
    const error = await indexer
      .process({
        chains: {
          1: { startBlock: 1, endBlock: 10, simulate: [note("${slipSig}", "${carol}", 5n)] },
        },
      })
      .then(() => "no error", (error: Error) => error.message);

    t.expect(error).toContain("never reached a handler");
  });
});
`,
)
