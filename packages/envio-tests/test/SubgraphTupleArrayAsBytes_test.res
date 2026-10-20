// `graph init` scaffolds an event's struct-array parameter as a `[Bytes!]!`
// field filled by `changetype<Bytes[]>(event.params.allocations)`. Under asc
// each struct is an ethereum.Tuple — an Array of ethereum.Value pointers — and
// read as a Uint8Array its bytes are those pointers: four little-endian bytes
// per field, at addresses graph-node's allocator picked (AssemblyScript's Array
// and Uint8Array share the ArrayBufferView header: buffer, dataStart,
// byteLength). Firstfruits' handleDesignated stopped the run instead. The
// field now holds as many bytes, at stand-in addresses, with a warning: the
// lengths match graph-node's, the addresses can't.
let manifest = `
specVersion: 1.3.0
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Firstfruits
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Firstfruits
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.9
      language: wasm/assemblyscript
      entities:
        - Designated
      abis:
        - name: Firstfruits
          file: ./abis/Firstfruits.json
      eventHandlers:
        - event: Designated(indexed address,(uint256,uint256)[])
          handler: handleDesignated
      file: ./src/firstfruits.ts
`

let schema = `
type Designated @entity(immutable: true) {
  id: Bytes!
  patron: Bytes!
  allocations: [Bytes!]!
}
`

let abi = `[{"type":"event","name":"Designated","anonymous":false,"inputs":[{"name":"patron","type":"address","indexed":true},{"name":"allocations","type":"tuple[]","indexed":false,"internalType":"struct Allocation[]","components":[{"name":"causeId","type":"uint256","internalType":"uint256"},{"name":"bps","type":"uint256","internalType":"uint256"}]}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Firstfruits.json", abi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Firstfruits.json", abi),
    ("generated/.gitkeep", ""),
    (
      "src/firstfruits.ts",
      `
import { Bytes } from "@graphprotocol/graph-ts";
import { Designated as DesignatedEvent } from "../generated/Firstfruits/Firstfruits";
import { Designated } from "../generated/schema";

export function handleDesignated(event: DesignatedEvent): void {
  let entity = new Designated(event.transaction.hash.concatI32(event.logIndex.toI32()));
  entity.patron = event.params.patron;
  entity.allocations = changetype<Bytes[]>(event.params.allocations);
  entity.save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a struct array stored as Bytes[]", () => {
  it("holds each struct's field pointers, four bytes a field", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            {
              contract: "Firstfruits",
              event: "Designated",
              params: {
                patron: "0x2222222222222222222222222222222222222222",
                allocations: [
                  { causeId: 1n, bps: 6000n },
                  { causeId: 2n, bps: 4000n },
                ],
              },
            },
          ],
        },
      },
    });
    const rows = await indexer.Designated.getAll();
    t.expect(rows.map((row: any) => row.allocations.map((bytes: Uint8Array) => bytes.length))).toEqual([[8, 8]]);
  });
});
`,
)
