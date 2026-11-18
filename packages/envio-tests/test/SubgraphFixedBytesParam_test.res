// A `bytesN` (N < 32) event parameter and an indexed dynamic one, as the
// HyperSync decoder hands them over: every `bytesN` as its full 32-byte word
// (ENS `InterfaceChanged(indexed bytes4)` stored `0x7ba18ba1` padded to 32
// bytes), and an indexed `string`/`bytes` as its topic, the keccak hash.
// graph-node keeps the first N bytes of a `bytesN` (to_from/external.rs) and
// hands an indexed dynamic value over as that 32-byte topic, a `FixedBytes`
// that graph codegen reads with `toBytes()`.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Resolver
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Resolver
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Probe
      abis:
        - name: Resolver
          file: ./abis/Resolver.json
      eventHandlers:
        - event: InterfaceChanged(indexed bytes32,indexed bytes4,address)
          handler: handleInterfaceChanged
        - event: TextChanged(indexed bytes32,indexed string,string)
          handler: handleTextChanged
        - event: Tagged(bytes16,bytes4[],indexed bytes)
          handler: handleTagged
      file: ./src/resolver.ts
`,
  ~schema=`
type Probe @entity {
  id: ID!
  value: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Resolver.json",
      `[{"type":"event","name":"InterfaceChanged","anonymous":false,"inputs":[{"name":"node","type":"bytes32","indexed":true},{"name":"interfaceID","type":"bytes4","indexed":true},{"name":"implementer","type":"address","indexed":false}]},{"type":"event","name":"TextChanged","anonymous":false,"inputs":[{"name":"node","type":"bytes32","indexed":true},{"name":"indexedKey","type":"string","indexed":true},{"name":"key","type":"string","indexed":false}]},{"type":"event","name":"Tagged","anonymous":false,"inputs":[{"name":"tag","type":"bytes16","indexed":false},{"name":"selectors","type":"bytes4[]","indexed":false},{"name":"blob","type":"bytes","indexed":true}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/resolver.ts",
      `
import { Address, Bytes, Entity, ethereum, store } from "@graphprotocol/graph-ts";

function probe(id: string, value: string): void {
  let entity = new Entity();
  entity.setString("value", value);
  store.set("Probe", id, entity);
}

// What graph codegen emits: an indexed string is read as bytes32.
export class TextChanged__Params {
  _event: TextChanged;
  constructor(event: TextChanged) {
    this._event = event;
  }
  get node(): Bytes {
    return this._event.parameters[0].value.toBytes();
  }
  get indexedKey(): Bytes {
    return this._event.parameters[1].value.toBytes();
  }
  get key(): string {
    return this._event.parameters[2].value.toString();
  }
}

export class TextChanged extends ethereum.Event {
  get params(): TextChanged__Params {
    return new TextChanged__Params(this);
  }
}

export class Tagged__Params {
  _event: Tagged;
  constructor(event: Tagged) {
    this._event = event;
  }
  get tag(): Bytes {
    return this._event.parameters[0].value.toBytes();
  }
  get selectors(): Array<Bytes> {
    return this._event.parameters[1].value.toBytesArray();
  }
  get blob(): Bytes {
    return this._event.parameters[2].value.toBytes();
  }
}

export class Tagged extends ethereum.Event {
  get params(): Tagged__Params {
    return new Tagged__Params(this);
  }
}

export function handleInterfaceChanged(event: any): void {
  probe("interfaceID", event.params.interfaceID.toHexString());
  let parameter: ethereum.Value = event.parameters[1].value;
  probe("interfaceIDValue", parameter.kind.toString() + ":" + parameter.toBytes().toHexString());
}

export function handleTextChanged(event: TextChanged): void {
  probe("indexedKey", event.params.indexedKey.toHexString());
  probe("indexedKeyKind", event.parameters[1].value.kind.toString());
  probe("key", event.params.key);
}

export function handleTagged(event: Tagged): void {
  probe("tag", event.params.tag.toHexString());
  let selectors: string[] = [];
  for (let i = 0; i < event.params.selectors.length; i++) selectors.push(event.params.selectors[i].toHexString());
  probe("selectors", selectors.join(","));
  probe("blob", event.params.blob.toHexString());
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const word = (hex: string) => hex.padEnd(66, "0");
const urlHash = "0x0c3b1ea0b1b9a1c8b7a7e3d6e2b4a5f6e7d8c9b0a1f2e3d4c5b6a7980f1e2d3c";
const blobHash = "0x5f16f4c7f149ac4f9510d9cf8cf384038ad348b3bcdc01915f95de12df9d1b02";

describe("a bytesN or indexed dynamic event parameter", () => {
  it("reads as graph-node decodes it", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            {
              contract: "Resolver",
              event: "InterfaceChanged",
              params: {
                node: word("0xaa"),
                interfaceID: word("0x7ba18ba1"),
                implementer: "0x2222222222222222222222222222222222222222",
              },
              block: { number: 10 },
            },
            {
              contract: "Resolver",
              event: "TextChanged",
              params: { node: word("0xaa"), indexedKey: urlHash, key: "url" },
              block: { number: 11 },
            },
            {
              contract: "Resolver",
              event: "Tagged",
              params: {
                tag: word("0x0102030405060708090a0b0c0d0e0f10"),
                selectors: [word("0xa9059cbb"), word("0x095ea7b3")],
                blob: blobHash,
              },
              block: { number: 12 },
            },
          ],
        },
      },
    });

    const probes = Object.fromEntries((await indexer.Probe.getAll()).map((p) => [p.id, p.value]));
    t.expect(probes).toEqual({
      interfaceID: "0x7ba18ba1",
      interfaceIDValue: "1:0x7ba18ba1",
      indexedKey: urlHash,
      indexedKeyKind: "1",
      key: "url",
      tag: "0x0102030405060708090a0b0c0d0e0f10",
      selectors: "0xa9059cbb,0x095ea7b3",
      blob: blobHash,
    });
  });
});
`,
)
