// beefyfinance/beefy-balances binds the vaults deployed before its factories
// from a `polling` handler on a data source that lives for one block
// (startBlock = endBlock), creating a BeefyERC20Product template for each. A
// polling handler matches every `every`th block from its data source's start
// (chain/ethereum/src/data_source.rs, `handler_for_block`:
// `(block - start_block) % every == 0`), and what it creates is indexed from
// that block on, as from any other trigger.
let manifest = `
specVersion: 0.0.9
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: ConfigBinder
    network: mainnet
    source:
      address: "0x000000000000000000000000000000000000dEaD"
      abi: Product
      startBlock: 3
      endBlock: 3
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Holding
      abis:
        - name: Product
          file: ./abis/Product.json
      blockHandlers:
        - handler: bindOldProducts
          filter:
            kind: polling
            every: 1
      file: ./src/binder.ts
  - kind: ethereum/contract
    name: Ticker
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Product
      startBlock: 2
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Holding
      abis:
        - name: Product
          file: ./abis/Product.json
      blockHandlers:
        - handler: handleTick
          filter:
            kind: polling
            every: 3
      file: ./src/binder.ts
templates:
  - kind: ethereum/contract
    name: BeefyERC20Product
    network: mainnet
    source:
      abi: Product
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Holding
      abis:
        - name: Product
          file: ./abis/Product.json
      eventHandlers:
        - event: Transfer(uint256)
          handler: handleTransfer
      file: ./src/product.ts
`

let abi = `[{"type":"event","name":"Transfer","anonymous":false,"inputs":[{"name":"value","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema=`
type Holding @entity {
  id: ID!
  transfers: Int!
}
`,
  ~files=Dict.fromArray([("./abis/Product.json", abi)]),
  ~mappings=Dict.fromArray([
    // What graph codegen writes to generated/templates.ts.
    (
      "src/templates.ts",
      `
import { Address, DataSourceTemplate } from "@graphprotocol/graph-ts";

export class BeefyERC20Product extends DataSourceTemplate {
  static create(address: Address): void {
    DataSourceTemplate.create("BeefyERC20Product", [address.toHex()]);
  }
}
`,
    ),
    (
      "src/binder.ts",
      `
import { Address, ethereum } from "@graphprotocol/graph-ts";
import { BeefyERC20Product as BeefyERC20ProductTemplate } from "./templates";

export function bindOldProducts(block: ethereum.Block): void {
  BeefyERC20ProductTemplate.create(Address.fromString("0x4444444444444444444444444444444444444444"));
}

export function handleTick(block: ethereum.Block): void {
  if (block.number.toI32() == 8) {
    BeefyERC20ProductTemplate.create(Address.fromString("0x5555555555555555555555555555555555555555"));
  }
}
`,
    ),
    (
      "src/product.ts",
      `
import { Entity, Value, ethereum, store } from "@graphprotocol/graph-ts";

export function handleTransfer(event: ethereum.Event): void {
  let id = event.address.toHexString();
  let holding = store.get("Holding", id);
  if (holding == null) {
    holding = new Entity();
    holding.set("id", Value.fromString(id));
    holding.set("transfers", Value.fromI32(0));
  }
  holding.set("transfers", Value.fromI32(holding.getI32("transfers") + 1));
  store.set("Holding", id, holding);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

const transfer = (address, block) => ({
  contract: "BeefyERC20Product",
  event: "Transfer",
  params: { value: 1n },
  srcAddress: address,
  block: { number: block },
});

describe("a polling block handler that creates a contract template", () => {
  it("indexes the instance from the polled block that created it", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({
      chains: {
        1: {
          startBlock: 2,
          endBlock: 12,
          simulate: [
            transfer("0x4444444444444444444444444444444444444444", 3),
            transfer("0x4444444444444444444444444444444444444444", 6),
            transfer("0x5555555555555555555555555555555555555555", 8),
            transfer("0x5555555555555555555555555555555555555555", 11),
          ],
        },
      },
    });
    t.expect(await indexer.Holding.getAll()).toEqual([
      { id: "0x4444444444444444444444444444444444444444", transfers: 2 },
      { id: "0x5555555555555555555555555555555555555555", transfers: 2 },
    ]);
  });
});
`,
)
