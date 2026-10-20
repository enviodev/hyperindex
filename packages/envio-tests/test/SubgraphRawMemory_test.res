// AssemblyScript code can address memory: `x.dataStart` and
// `changetype<usize>(x.buffer)` are pointers, `load<T>`/`store<T>` read and
// write a little-endian T there, `memory.copy` moves bytes, and `bswap`,
// `rotr`, `min` are builtins of the operand's type, and a `StaticArray<u32>`
// keeps u32s. Kiln vSuite verifies its validators' BLS signatures with a
// vendored SHA-256 written this way; run so, it hashes as asc 0.19.10's build of
// it does for every length checked (0-300 bytes, including where that copy
// differs from SHA-256, past 127).
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Registry
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Registry
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Check
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(uint256)
          handler: handleNewOwner
      file: ./src/registry.ts
`,
  ~schema=`
type Check @entity {
  id: ID!
  copied: Bytes!
  word: BigInt!
  stored: Bytes!
  rotated: BigInt!
  smaller: Int!
  wrapped: Int!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/bytes.ts",
      `
export function setU8(t: Uint8Array, s: Uint8Array, o: isize = 0): void {
  memory.copy(t.dataStart + o, s.dataStart, s.length);
}

export function load32_be(x: Uint8Array, offset: isize): u32 {
  return bswap(load<u32>(changetype<usize>(x.buffer) + offset));
}

export function store64_be(x: Uint8Array, offset: isize, u: u64): void {
  store<u64>(changetype<usize>(x.buffer) + offset, bswap(u));
}

export function rotated(high: u32): u32 {
  return rotr(high, 1);
}

export function wrapped(): u32 {
  let words = new StaticArray<u32>(2);
  words[0] += 4294967295;
  words[0] += 2;
  return words[0] + words[1];
}
`,
    ),
    (
      "src/registry.ts",
      `
import { BigInt, Bytes, Entity, store } from "@graphprotocol/graph-ts";
import { load32_be, rotated, setU8, store64_be, wrapped } from "./bytes";

export function handleNewOwner(event: any): void {
  let copied = new Uint8Array(8);
  setU8(copied, Bytes.fromHexString("0x01020304"), 2);
  let stored = new Uint8Array(8);
  store64_be(stored, 0, 256);
  let high: u32 = 0x80000001;

  let check = new Entity();
  check.setBytes("copied", Bytes.fromUint8Array(copied));
  check.setBigInt("word", BigInt.fromU32(load32_be(copied, 2)));
  check.setBytes("stored", Bytes.fromUint8Array(stored));
  check.setBigInt("rotated", BigInt.fromU32(rotated(high)));
  check.setI32("smaller", min(3, 7));
  check.setI32("wrapped", wrapped());
  store.set("Check", "c1", check);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const hex = (bytes: Uint8Array) => "0x" + Buffer.from(bytes).toString("hex");

describe("raw memory", () => {
  it("reads and writes through pointers, as AssemblyScript does", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Registry", event: "NewOwner", params: { nonce: 1n } }] } },
    });
    const check = await indexer.Check.getOrThrow("c1");
    t.expect({ ...check, copied: hex(check.copied), stored: hex(check.stored) }).toEqual({
      id: "c1",
      copied: "0x0000010203040000",
      word: 16909060n,
      stored: "0x0000000000000100",
      rotated: 3221225472n,
      smaller: 3,
      wrapped: 1,
    });
  });
});
`,
)
