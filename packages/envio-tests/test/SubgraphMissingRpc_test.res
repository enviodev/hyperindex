// subgraph.yaml has nowhere to put an RPC endpoint — graph-node keeps provider
// config in its own config, not in the project. So a mapping that calls a
// contract with nothing configured has to say what to set and where.
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
  name: String!
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
import { Address, ethereum } from "@graphprotocol/graph-ts";

class Token extends ethereum.SmartContract {
  static bind(address: Address): Token {
    return new Token("Token", address);
  }
  try_name(): any {
    return this.tryCall("name", "name():(string)", []);
  }
}

export function handlePing(event: any): void {
  let nonce = event.params.nonce.toI32();

  if (nonce === 2) {
    ethereum.getBalance(event.address);
    return;
  }
  if (nonce === 3) {
    ethereum.hasCode(event.address);
    return;
  }

  // A revert is data, so a missing endpoint must not arrive here as one.
  Token.bind(event.address).try_name();
}
`,
    ),
  ]),
  ~test=`
import { describe, expect, it } from "vitest";
import { createTestIndexer } from "envio";

const ping = (nonce: bigint) => ({
  chains: {
    1: { simulate: [{ contract: "Token", event: "Ping", params: { nonce } }] },
  },
});

describe("a mapping that needs an RPC with none configured", () => {
  it("names the call site and what to set", async () => {
    await expect(createTestIndexer().process(ping(1n))).rejects.toThrow(
      /contract calls \\(name\\(\\):\\(string\\)\\).*ENVIO_SUBGRAPH_RPC=https:\\/\\/\\.\\.\\./s,
    );
  });

  it("says the same for ethereum.getBalance", async () => {
    await expect(createTestIndexer().process(ping(2n))).rejects.toThrow(
      /ethereum\\.getBalance.*ENVIO_SUBGRAPH_RPC/s,
    );
  });

  it("says the same for ethereum.hasCode", async () => {
    await expect(createTestIndexer().process(ping(3n))).rejects.toThrow(
      /ethereum\\.hasCode.*ENVIO_SUBGRAPH_RPC/s,
    );
  });
});
`,
)
