// Places where the shim and the real graph-ts had drifted apart. Each of these
// is silent on graph-node: the mapping compiles, runs, and stores a wrong
// value.
let _ = InternalTestIndexer.fromSubgraph(
  ~manifest=`
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: Probe
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Probe
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Result
      abis:
        - name: Probe
          file: ./abis/Probe.json
      eventHandlers:
        - event: Ping(uint256)
          handler: handlePing
      file: ./src/probe.ts
`,
  ~schema=`
type Result @entity {
  id: ID!
  value: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Probe.json",
      `[{"type":"event","name":"Ping","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/probe.ts",
      `
import { BigDecimal, BigInt, Bytes, Entity, EthereumUtils, store, typeConversion } from "@graphprotocol/graph-ts";

function probe(id: string, value: string): void {
  let result = new Entity();
  result.setString("value", value);
  store.set("Result", id, result);
}

export function handlePing(event: any): void {
  let amount: BigInt = event.params.amount;

  // A BigInt reaches these as itself, not as the bytes AssemblyScript would
  // have laid it out in.
  probe("bigIntToString", typeConversion.bigIntToString(amount));
  probe("bigIntToHex", typeConversion.bigIntToHex(amount));

  // graph-ts assigns each source in turn, so the last one wins a shared key.
  let base = new Entity();
  base.setString("value", "base");
  let first = new Entity();
  first.setString("value", "first");
  let second = new Entity();
  second.setString("value", "second");
  store.set("Result", "merge", base.merge([first, second]));

  // AssemblyScript truncates integer division, and \`/=\` is division too.
  let quotient = 7;
  quotient /= 2;
  probe("compoundDivision", quotient.toString());

  // graph-node carries 34 significant digits, so a small quotient survives.
  probe(
    "smallQuotient",
    BigDecimal.fromString("1").div(BigDecimal.fromString("1000000000000000000000000000000")).toString(),
  );
  probe(
    "thirds",
    BigDecimal.fromString("1").div(BigDecimal.fromString("3")).toString(),
  );

  probe(
    "create2",
    EthereumUtils.getCreate2Address(
      Bytes.fromHexString("0x5FbDB2315678afecb367f032d93F642f64180aa3"),
      Bytes.fromHexString("0x0000000000000000000000000000000000000000000000000000000000000001"),
      Bytes.fromHexString("0x00000000000000000000000000000000000000000000000000000000000000ff"),
    ).toHexString(),
  );
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("the graph-ts surface", () => {
  it("answers what the real package answers", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: { simulate: [{ contract: "Probe", event: "Ping", params: { amount: 255n } }] },
      },
    });

    const value = async (id) => (await indexer.Result.getOrThrow(id)).value;

    t.expect({
      bigIntToString: await value("bigIntToString"),
      bigIntToHex: await value("bigIntToHex"),
      merge: await value("merge"),
      compoundDivision: await value("compoundDivision"),
      smallQuotient: await value("smallQuotient"),
      thirds: await value("thirds"),
      create2: await value("create2"),
    }).toEqual({
      bigIntToString: "255",
      bigIntToHex: "0xff",
      merge: "second",
      compoundDivision: "3",
      smallQuotient: "0.000000000000000000000000000001",
      thirds: "0.3333333333333333333333333333333333",
      // Cross-checked against viem's own getCreate2Address, which shares no
      // code with the shim's.
      create2: "0x4f2009bbb6b8238db8d2f37112e85902d5155077",
    });
  });
});
`,
)
