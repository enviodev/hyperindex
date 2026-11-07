// Two gaps the call-handler subgraphs hit before their handlers ran:
// Polymarket's resolution mapping tests an update string with
// `assemblyscript-regex` (a library of AssemblyScript's own memory-level
// matching, which has no JavaScript to run as), and Croc left-pads the hex of
// a `ByteArray` with zeros ahead of its `0x`, which graph-ts reads as a zero
// byte where a strict hex decoder throws.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Token
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Token
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Token
          file: ./abis/Token.json
      eventHandlers:
        - event: Ping(uint256)
          handler: handlePing
      file: ./src/token.ts
`,
  ~schema=`
type Probe @entity {
  id: ID!
  label: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Token.json",
      `[{"type":"event","name":"Ping","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/token.ts",
      `
import { Bytes, ByteArray, Entity, store } from "@graphprotocol/graph-ts";
import { RegExp } from "assemblyscript-regex";

const REVISION = new RegExp("^REVISION:");

export function handlePing(event: any): void {
  let padded = Bytes.fromHexString("0x00000000".padStart(64, "0"));
  let probe = new Entity();
  probe.setString(
    "label",
    [
      REVISION.test("REVISION: 1").toString(),
      REVISION.test("not REVISION:").toString(),
      new RegExp("(a)(b)?").exec("xab")!.matches.join("|"),
      padded.length.toString(),
      padded.toHexString(),
    ].join(" ")
  );
  store.set("Probe", "p", probe);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("call-handler subgraph shims", () => {
  it("run assemblyscript-regex and read a zero-padded 0x pair as a zero byte", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { startBlock: 0, endBlock: 5, simulate: [{ contract: "Token", event: "Ping", params: { nonce: 1n } }] } },
    });
    const [probe] = await indexer.Probe.getAll();
    t.expect(probe.label).toBe("true false ab|a|b 32 0x" + "00".repeat(32));
  });
});
`,
)
