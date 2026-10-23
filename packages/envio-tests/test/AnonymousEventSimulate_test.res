// A simulated anonymous log reaches only the registrations whose first indexed
// param filter names its value.
let guy = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
let fileSig = "0x29ae8114"
let slipSig = "0x7cdd3fde"

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: simulate-anonymous-where-params
contracts:
  - name: Vat
    events:
      - event: LogNote(bytes4 indexed sig, address indexed guy, uint256 wad) anonymous
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Vat
        address: "0x1111111111111111111111111111111111111111"
`,
  ~schema=`
type Note {
  id: ID!
  wad: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent(
  { contract: "Vat", event: "LogNote", where: { params: { sig: "${fileSig}" } } },
  async ({ event, context }) => {
    context.Note.set({ id: "file-" + event.params.wad, wad: event.params.wad });
  },
);
indexer.onEvent(
  { contract: "Vat", event: "LogNote", where: { params: { sig: "${slipSig}" } } },
  async ({ event, context }) => {
    context.Note.set({ id: "slip-" + event.params.wad, wad: event.params.wad });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const note = (sig: \`0x\${string}\`, wad: bigint) =>
  ({ contract: "Vat", event: "LogNote", params: { sig, guy: "${guy}", wad } }) as const;

describe("simulate an anonymous event", () => {
  it("runs only the handler whose sig matches the item", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { startBlock: 1, endBlock: 10, simulate: [note("${fileSig}", 1n), note("${slipSig}", 2n)] } },
    });

    t.expect(
      (await indexer.Note.getAll()).toSorted((a, b) => a.id.localeCompare(b.id)),
    ).toEqual([
      { id: "file-1", wad: 1n },
      { id: "slip-2", wad: 2n },
    ]);
  });
});
`,
)
