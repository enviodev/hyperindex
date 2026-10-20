// AssemblyScript divides two integers as integers and anything with a float
// side as floats. The runtime can only tell from the values, so a float that
// holds a whole number divided as an integer: Notional's
// `(lendRate as f64 * timeToMaturity) / (YEAR as f64 * RATE_PRECISION)` came
// out 0 where asc computes 0.5. A division with a side the source types as a
// float — a float literal, an `as f64` cast, parseFloat, a Math function, a
// name or parameter declared or initialized so — is now a float division.
// Expected values are asc 0.19.10's build of the same code.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Vault
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Vault
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Term
      abis:
        - name: Vault
          file: ./abis/Vault.json
      eventHandlers:
        - event: Lend(uint256,uint256)
          handler: handleLend
      file: ./src/vault.ts
`,
  ~schema=`
type Term @entity {
  id: ID!
  values: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Vault.json",
      `[{"type":"event","name":"Lend","anonymous":false,"inputs":[{"name":"rate","type":"uint256","indexed":false},{"name":"time","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/vault.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";

const YEAR: i32 = 31536000;
const RATE_PRECISION: i32 = 1000;

function half(v: f64): f64 {
  return v / 2;
}

export function handleLend(event: any): void {
  let lendRate: i64 = event.params.rate.toI64();
  let time: i32 = event.params.time.toI32();
  let term: f64 = (lendRate as f64 * time) / (YEAR as f64 * RATE_PRECISION);
  let pct = parseFloat("50") / 100;
  let x: f64 = 9;
  x /= 2;
  let y = 7.0;
  let z = y / 2;
  let w = Math.floor(7.0) / 2;
  let k: i32 = 7;
  let q = k / 2;
  let entity = new Entity();
  entity.setString("values", term.toString() + " " + pct.toString() + " " + x.toString() + " " + z.toString() + " " + w.toString() + " " + q.toString() + " " + half(5).toString());
  store.set("Term", "t", entity);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a division with a float side", () => {
  it("divides as floats, as asc compiles it", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: { 1: { simulate: [{ contract: "Vault", event: "Lend", params: { rate: 500n, time: 31536000n } }] } },
    });
    t.expect(await indexer.Term.getAll()).toEqual([{ id: "t", values: "0.5 0.5 4.5 3.5 3.5 3 2.5" }]);
  });
});
`,
)
