// AssemblyScript has a file's classes and constant-initialized globals from
// the start: asc compiles a class at compile time and gives a global with a
// constant initializer that value as its initial one (asc 0.19.10
// `compileGlobal`: only other initializers run in the start function). An ES
// module's class and `const` are in their temporal dead zone until its body
// runs, so a file evaluated first inside an import cycle threw where asc reads
// them: Opolis' `ERC20/index.ts` reads `Token.ts`'s `ethAddress`, and Flaunch's
// `addresses/base.ts` builds `addresses/index.ts`'s `PositionManagerMapping`.
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
        - Token
      abis:
        - name: Registry
          file: ./abis/Registry.json
      eventHandlers:
        - event: NewOwner(address)
          handler: handleNewOwner
      file: ./src/mapping.ts
`,
  ~schema=`
type Token @entity {
  id: ID!
  symbol: String!
  bidwall: String!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Registry.json",
      `[{"type":"event","name":"NewOwner","anonymous":false,"inputs":[{"name":"owner","type":"address","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/mapping.ts",
      `
import { Entity, store } from "@graphprotocol/graph-ts";
import { symbolOf } from "./entities/Token";
import { positionManagers } from "./addresses";

export function handleNewOwner(event: any): void {
  let token = new Entity();
  token.setString("symbol", symbolOf(event.params.owner));
  token.setString("bidwall", positionManagers.get("flaunch")!.bidwall);
  store.set("Token", "t1", token);
}
`,
    ),
    (
      "src/entities/Token.ts",
      `
import { Address } from "@graphprotocol/graph-ts";
import { ERC20 } from "../utils/ERC20";

export const ethAddress = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";

export function symbolOf(address: Address): string {
  return new ERC20(Address.fromString(ethAddress)).symbol;
}
`,
    ),
    (
      "src/utils/ERC20.ts",
      `
import { Address } from "@graphprotocol/graph-ts";
import { ethAddress } from "../entities/Token";

const ethAddressConverted = Address.fromHexString(ethAddress);

export class ERC20 {
  address: Address;

  constructor(address: Address) {
    this.address = address;
  }

  get symbol(): string {
    return this.address == ethAddressConverted ? "ETH" : "?";
  }
}
`,
    ),
    (
      "src/addresses/index.ts",
      `
export class PositionManagerMapping {
  bidwall: string;

  constructor(bidwall: string) {
    this.bidwall = bidwall;
  }
}

export * from "./base";
`,
    ),
    (
      "src/addresses/base.ts",
      `
import { PositionManagerMapping } from ".";

export const positionManagers = new Map<string, PositionManagerMapping>();
positionManagers.set("flaunch", new PositionManagerMapping("0xb1d"));
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("an import cycle", () => {
  it("reads a class and a constant before the file declaring them has run", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Registry", event: "NewOwner", params: { owner: "0x2222222222222222222222222222222222222222" } },
          ],
        },
      },
    });

    t.expect(await indexer.Token.getOrThrow("t1")).toEqual({ id: "t1", symbol: "ETH", bidwall: "0xb1d" });
  });
});
`,
)
