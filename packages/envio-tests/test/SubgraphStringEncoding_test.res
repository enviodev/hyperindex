// AssemblyScript's String namespace encodes and decodes UTF-8 and UTF-16 over
// ArrayBuffers (std/assembly/string.ts in asc 0.19.10: `String.UTF8.decode`,
// `encode`, `byteLength`, and `String.UTF16`'s). JavaScript's String has none of
// them: oddmaki's `String.UTF8.decode(trimmed.buffer)` turned its bytes32 market
// tags into text and stopped at the first MarketCreated.
// The decoder is AssemblyScript's: it reads up to the first zero byte only when
// asked to, and decodes what it is given without replacing anything.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Market
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Market
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Tagged
      abis:
        - name: Market
          file: ./abis/Market.json
      eventHandlers:
        - event: MarketCreated(bytes32[])
          handler: handleMarketCreated
      file: ./src/market.ts
`,
  ~schema=`
type Tagged @entity {
  id: ID!
  tags: [String!]!
  decoded: String!
  untilZero: String!
  encoded: Bytes!
  terminated: Bytes!
  byteLength: Int!
  terminatedLength: Int!
  wide: Bytes!
  wideBack: String!
  wideLength: Int!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Market.json",
      `[{"type":"event","name":"MarketCreated","anonymous":false,"inputs":[{"name":"tags","type":"bytes32[]","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/market.ts",
      `
import { Bytes, Entity, Value, store } from "@graphprotocol/graph-ts";

function decodeTags(tags: Bytes[]): string[] {
  let result: string[] = [];
  for (let i = 0; i < tags.length; i++) {
    let raw = tags[i];
    let end = raw.length;
    while (end > 0 && raw[end - 1] == 0) {
      end--;
    }
    let trimmed = new Uint8Array(end);
    for (let j = 0; j < end; j++) {
      trimmed[j] = raw[j];
    }
    result.push(String.UTF8.decode(trimmed.buffer));
  }
  return result;
}

export function handleMarketCreated(event: any): void {
  let text = Uint8Array.wrap(String.UTF8.encode("héllo")).buffer;
  let zeroed = Bytes.fromHexString("0x6162006364");
  let entity = new Entity();
  entity.set("tags", Value.fromStringArray(decodeTags(event.params.tags)));
  entity.setString("decoded", String.UTF8.decode(text));
  entity.setString("untilZero", String.UTF8.decode(zeroed.buffer, true) + "|" + String.UTF8.decode(zeroed.buffer).length.toString());
  entity.setBytes("encoded", Bytes.fromUint8Array(Uint8Array.wrap(String.UTF8.encode("a€😀"))));
  entity.setBytes("terminated", Bytes.fromUint8Array(Uint8Array.wrap(String.UTF8.encode("ab", true))));
  entity.setI32("byteLength", String.UTF8.byteLength("a€😀"));
  entity.setI32("terminatedLength", String.UTF8.byteLength("ab", true));
  let wide = String.UTF16.encode("hé");
  entity.setBytes("wide", Bytes.fromUint8Array(Uint8Array.wrap(wide)));
  entity.setString("wideBack", String.UTF16.decode(wide));
  entity.setI32("wideLength", String.UTF16.byteLength("hé"));
  store.set("Tagged", "t1", entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const word = (text: string) => "0x" + Buffer.from(text).toString("hex").padEnd(64, "0");
const hex = (bytes: Uint8Array) => "0x" + Buffer.from(bytes).toString("hex");

describe("AssemblyScript's String.UTF8 and String.UTF16", () => {
  it("encode and decode as asc's standard library does", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Market", event: "MarketCreated", params: { tags: [word("crypto"), word("price-market")] } }] },
      },
    });
    const tagged = await indexer.Tagged.getOrThrow("t1");
    t.expect({ ...tagged, encoded: hex(tagged.encoded), terminated: hex(tagged.terminated), wide: hex(tagged.wide) }).toEqual({
      id: "t1",
      tags: ["crypto", "price-market"],
      decoded: "héllo",
      untilZero: "ab|5",
      encoded: "0x61e282acf09f9880",
      terminated: "0x616200",
      byteLength: 8,
      terminatedLength: 3,
      wide: "0x6800e900",
      wideBack: "hé",
      wideLength: 4,
    });
  });
});
`,
)
