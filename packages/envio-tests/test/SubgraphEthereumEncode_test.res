// `ethereum.encode` is graph-node's `ethabi::encode(&[token])`: Solidity's
// `abi.encode` of one value. Nouns hashes every proposal's content with it
// (`calcEncodedProposalHash`) and links candidates to proposals through that
// hash, so the bytes have to match exactly. It used to be a refusal.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Dao
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Dao
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Encoded
      abis:
        - name: Dao
          file: ./abis/Dao.json
      eventHandlers:
        - event: Proposed(uint256)
          handler: handleProposed
      file: ./src/dao.ts
`,
  ~schema=`
type Encoded @entity {
  id: ID!
  hex: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Dao.json",
      `[{"type":"event","name":"Proposed","anonymous":false,"inputs":[{"name":"id","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/dao.ts",
      `
import { Address, BigInt, Bytes, Entity, ethereum, store } from "@graphprotocol/graph-ts";

function save(id: string, value: ethereum.Value): void {
  let entity = new Entity();
  entity.setString("hex", ethereum.encode(value)!.toHexString());
  store.set("Encoded", id, entity);
}

export function handleProposed(event: any): void {
  let id: BigInt = event.params.id;
  let targets = [ethereum.Value.fromAddress(Address.fromString("0x2222222222222222222222222222222222222222"))];
  let values = [ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(5))];
  let signatures = [ethereum.Value.fromString("transfer(address,uint256)")];
  let calldatas = [ethereum.Value.fromBytes(Bytes.fromHexString("0xdeadbeef"))];
  let tuple = new ethereum.Tuple();
  tuple.push(ethereum.Value.fromArray(targets));
  tuple.push(ethereum.Value.fromArray(values));
  tuple.push(ethereum.Value.fromArray(signatures));
  tuple.push(ethereum.Value.fromArray(calldatas));
  tuple.push(ethereum.Value.fromString("# Title"));
  save("proposal", ethereum.Value.fromTuple(tuple));

  let flat = new ethereum.Tuple();
  flat.push(ethereum.Value.fromUnsignedBigInt(id));
  flat.push(ethereum.Value.fromSignedBigInt(BigInt.fromI32(-3)));
  flat.push(ethereum.Value.fromBoolean(true));
  flat.push(ethereum.Value.fromFixedBytes(Bytes.fromHexString("0x" + "ab".repeat(32))));
  save("flat", ethereum.Value.fromTuple(flat));

  save("uint", ethereum.Value.fromUnsignedBigInt(id));
  save("bytes", ethereum.Value.fromBytes(Bytes.fromHexString("0x01")));
  // Reserve's encodeAndHash: an array of unlike values encodes element by
  // element, and past its offset and length that is the tuple's encoding.
  save("mixed", ethereum.Value.fromArray([
    ethereum.Value.fromAddressArray([Address.fromString("0x2222222222222222222222222222222222222222")]),
    ethereum.Value.fromUnsignedBigIntArray([BigInt.fromU64(0)]),
    ethereum.Value.fromBytesArray([Bytes.fromHexString("0xdeadbeef")]),
    ethereum.Value.fromUnsignedBigInt(BigInt.fromU64(0)),
    ethereum.Value.fromFixedBytes(Bytes.fromHexString("0x" + "cd".repeat(32))),
  ]));
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";
import { encodeAbiParameters, parseAbiParameters } from "viem";

describe("ethereum.encode", () => {
  it("encodes one value the way abi.encode does", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Dao", event: "Proposed", params: { id: 42n } }] } },
    });

    const abiEncode = (types: string, values: unknown[]) =>
      encodeAbiParameters(parseAbiParameters(types), values as any);

    t.expect(
      Object.fromEntries((await indexer.Encoded.getAll()).map((row: any) => [row.id, row.hex])),
    ).toEqual({
      proposal: abiEncode("(address[],uint256[],string[],bytes[],string)", [
        [["0x2222222222222222222222222222222222222222"], [5n], ["transfer(address,uint256)"], ["0xdeadbeef"], "# Title"],
      ]),
      flat: abiEncode("(uint256,int256,bool,bytes32)", [[42n, -3n, true, "0x" + "ab".repeat(32)]]),
      uint: abiEncode("uint256", [42n]),
      bytes: abiEncode("bytes", ["0x01"]),
      mixed:
        abiEncode("uint256,uint256", [32n, 5n]) +
        abiEncode("address[],uint256[],bytes[],uint256,bytes32", [
          ["0x2222222222222222222222222222222222222222"],
          [0n],
          ["0xdeadbeef"],
          0n,
          "0x" + "cd".repeat(32),
        ]).slice(2),
    });
  });
});
`,
)
