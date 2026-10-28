// Live cross-check of anonymous events over HyperSync against a public RPC
// node: a DSNote-style `LogNote` on a mainnet contract, selected by function
// selector, must give one row per log the node holds over a pinned range.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live anonymous event test",
  )

let noteEmitter = "0xbE286431454714F511008713973d3B053A2d38f3"
let selectors = ["0x168ccd67", "0x46d2fbbb", "0x162c7de3"]
// A range holding a few notes: the contract is used rarely.
let fromBlock = 26150000
let toBlock = 26290000

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: evm-anonymous-event-live
contracts:
  - name: Notes
    events:
      - event: LogNote(bytes4 indexed sig, address indexed guy, bytes32 indexed foo, bytes32 indexed bar, uint256 wad, bytes fax) anonymous
chains:
  - id: 1
    start_block: 1
    contracts:
      - name: Notes
        address: "${noteEmitter}"
`,
  ~schema=`
type Note {
  id: ID!
  sig: String!
  guy: String!
  number: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent(
  { contract: "Notes", event: "LogNote", where: { params: { sig: ${selectors
    ->JSON.stringifyAny
    ->Option.getOrThrow} } } },
  async ({ event, context }) => {
    context.Note.set({
      id: \`\${event.block.number}-\${event.logIndex}\`,
      sig: event.params.sig,
      guy: event.params.guy.toLowerCase(),
      number: event.block.number,
    });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const noteEmitter = "${noteEmitter}";
const selectors = ${selectors->JSON.stringifyAny->Option.getOrThrow};
const topics = selectors.map((selector) => selector + "0".repeat(56));
const fromBlock = ${fromBlock->Int.toString};
const toBlock = ${toBlock->Int.toString};

// A public node that answers eth_getLogs over older ranges; it is rate
// limited, so a refusal is asked again.
const rpc = async (method: string, params: unknown[]) => {
  for (let attempt = 0; ; attempt++) {
    try {
      const response = await fetch("https://rpc.mevblocker.io", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
      });
      const body = (await response.json()) as { error?: unknown; result: any };
      if (body.error) throw new Error(JSON.stringify(body.error));
      if (body.result !== null) return body.result;
      throw new Error(\`null result for \${method}\`);
    } catch (error) {
      if (attempt >= 8) throw error;
      await new Promise((resolve) => setTimeout(resolve, 500 * (attempt + 1)));
    }
  }
};
const hex = (n: number) => "0x" + n.toString(16);
const byId = (a: { id: string }, b: { id: string }) => a.id.localeCompare(b.id);

// The contract's notes with one of the selectors over the range, read in
// chunks the public node accepts.
const notesOnChain = async () => {
  const notes: any[] = [];
  for (let from = fromBlock; from <= toBlock; from += 50_000) {
    const logs = await rpc("eth_getLogs", [
      { address: noteEmitter, topics: [topics], fromBlock: hex(from), toBlock: hex(Math.min(from + 49_999, toBlock)) },
    ]);
    for (const log of logs) {
      notes.push({
        id: \`\${Number(log.blockNumber)}-\${Number(log.logIndex)}\`,
        sig: log.topics[0].slice(0, 10),
        guy: "0x" + log.topics[1].slice(26),
        number: Number(log.blockNumber),
      });
    }
  }
  return notes.sort(byId);
};

describe("anonymous events over live HyperSync", () => {
  it("writes one row per note the node holds, by selector", { timeout: 240_000 }, async (t) => {
    const expected = await notesOnChain();
    t.expect(expected.length > 0, "no note was emitted in the range").toBe(true);
    const indexer = createTestIndexer();
    await indexer.process({ chains: { 1: { startBlock: fromBlock, endBlock: toBlock } } });
    t.expect((await indexer.Note.getAll()).sort(byId)).toEqual(expected);
  });
});
`,
)
