open Vitest

// subgraph.yaml has nowhere to put an RPC endpoint — graph-node keeps provider
// config in its own config, not in the project. So a mapping that calls a
// contract with nothing configured is misconfigured, and saying so before
// indexing starts is the difference between a config error and a handler
// failure mid-batch.
let mapping = body => `
import { Address, ethereum, store } from "@graphprotocol/graph-ts";

class Token extends ethereum.SmartContract {
  static bind(address: Address): Token {
    return new Token("Token", address);
  }
  try_name(): any {
    return this.tryCall("name", "name():(string)", []);
  }
}

export function handlePing(event: any): void {
${body}
}
`

let translate = (~mapping as body, ~env=Dict.make()) =>
  try {
    InternalTestIndexer.fromSubgraph(
      ~env,
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
  name: String!
}
`,
      ~files=Dict.fromArray([
        (
          "abis/Token.json",
          `[{"type":"event","name":"Ping","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false}]}]`,
        ),
      ]),
      ~mappings=Dict.fromArray([("src/token.ts", body->mapping)]),
    )->ignore
    "the translation to fail, but it succeeded"
  } catch {
  | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
  }

let expectsAnEndpointFor = (message, t, ~callSite) =>
  t.expect((
    message->String.includes(`performs contract calls (${callSite})`),
    message->String.includes("ENVIO_SUBGRAPH_RPC=https://..."),
  ), ~message).toEqual((true, true))

describe("a mapping that needs an RPC with none configured", () => {
  it("names the binding it would have called through", t => {
    translate(~mapping=`  Token.bind(event.address).try_name();`)->expectsAnEndpointFor(
      t,
      ~callSite="Token.bind(...)",
    )
  })

  it("names ethereum.getBalance", t => {
    translate(~mapping=`  ethereum.getBalance(event.address);`)->expectsAnEndpointFor(
      t,
      ~callSite="ethereum.getBalance",
    )
  })

  it("names ethereum.hasCode", t => {
    translate(~mapping=`  ethereum.hasCode(event.address);`)->expectsAnEndpointFor(
      t,
      ~callSite="ethereum.hasCode",
    )
  })

  it("asks for nothing when the mapping only touches the store", t => {
    t.expect(
      translate(~mapping=`  store.remove("Probe", "probe");`),
    ).toBe("the translation to fail, but it succeeded")
  })

  it("asks for nothing once an endpoint is configured", t => {
    t.expect(
      translate(
        ~mapping=`  Token.bind(event.address).try_name();`,
        ~env=Dict.fromArray([("ENVIO_SUBGRAPH_RPC", "http://127.0.0.1:8599")]),
      ),
    ).toBe("the translation to fail, but it succeeded")
  })
})
