// A mapping that reads, adds and writes back, then reads an entity whose id it
// derives from what it just wrote. Preload can't predict that id — an earlier
// event in the batch moved the counter — so the read misses, the handler
// suspends, and the bridge replays it from the top. The aborted round's write
// must not be visible to the replay, or the increment lands once per round.
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
        - Account
        - Deposit
      abis:
        - name: Vault
          file: ./abis/Vault.json
      eventHandlers:
        - event: Deposited(uint256,uint256)
          handler: handleDeposited
      file: ./src/vault.ts
`,
  ~schema=`
type Account @entity {
  id: ID!
  balance: BigInt!
  deposits: Int!
}

type Deposit @entity {
  id: ID!
  amount: BigInt!
}
`,
  ~files=Dict.fromArray([
    (
      "abis/Vault.json",
      `[{"type":"event","name":"Deposited","anonymous":false,"inputs":[{"name":"nonce","type":"uint256","indexed":false},{"name":"amount","type":"uint256","indexed":false}]}]`,
    ),
  ]),
  ~mappings=Dict.fromArray([
    (
      "src/vault.ts",
      `
import { BigInt, Entity, store } from "@graphprotocol/graph-ts";

export function handleDeposited(event: any): void {
  let amount: BigInt = event.params.amount;

  let account = store.get("Account", "a");
  if (account == null) {
    account = new Entity();
    account.setBigInt("balance", BigInt.fromI32(0));
    account.setI32("deposits", 0);
  }
  account.setBigInt("balance", account.getBigInt("balance").plus(amount));
  account.setI32("deposits", account.getI32("deposits") + 1);
  store.set("Account", "a", account);

  let id = "d" + account.getI32("deposits").toString();
  let deposit = store.get("Deposit", id);
  if (deposit == null) {
    deposit = new Entity();
  }
  deposit.setBigInt("amount", amount);
  store.set("Deposit", id, deposit);
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a replayed mapping", () => {
  it("applies each increment once", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Vault", event: "Deposited", params: { nonce: 1n, amount: 10n } },
            { contract: "Vault", event: "Deposited", params: { nonce: 2n, amount: 10n } },
            { contract: "Vault", event: "Deposited", params: { nonce: 3n, amount: 10n } },
          ],
        },
      },
    });

    t.expect(await indexer.Account.getOrThrow("a")).toEqual({ id: "a", balance: 30n, deposits: 3 });
  });
});
`,
)
