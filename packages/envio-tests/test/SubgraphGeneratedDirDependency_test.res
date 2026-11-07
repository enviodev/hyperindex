// A mapping that ships in a dependency imports the generated code that ships with
// it: @openzeppelin/subgraphs' `src/datasources/voting.ts` imports
// `../../generated/schema`, inside its own package. That says nothing about where
// `graph codegen` writes this project's tree, which is where the project's own
// mappings import it from. Mento's manifest lists OpenZeppelin's data sources
// first, so envio took the package's directory for the project's, found it
// complete, and never generated the project's `generated/`.

let manifest = `
specVersion: 0.0.5
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum/contract
    name: voting
    network: mainnet
    source:
      address: "0x1111111111111111111111111111111111111111"
      abi: Voting
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Vote
      abis:
        - name: Voting
          file: ./abis/Voting.json
      eventHandlers:
        - event: Voted(uint256)
          handler: handleVoted
      file: ./node_modules/@openzeppelin/subgraphs/src/datasources/voting.ts
  - kind: ethereum/contract
    name: locking
    network: mainnet
    source:
      address: "0x2222222222222222222222222222222222222222"
      abi: Locking
      startBlock: 0
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - Lock
      abis:
        - name: Locking
          file: ./abis/Locking.json
      eventHandlers:
        - event: Locked(uint256)
          handler: handleLocked
      file: ./src/locking.ts
`

let schema = `
type Vote @entity {
  id: ID!
}

type Lock @entity {
  id: ID!
  amount: BigInt!
}
`

let votingAbi = `[{"type":"event","name":"Voted","anonymous":false,"inputs":[{"name":"weight","type":"uint256","indexed":false}]}]`
let lockingAbi = `[{"type":"event","name":"Locked","anonymous":false,"inputs":[{"name":"amount","type":"uint256","indexed":false}]}]`

let _ = InternalTestIndexer.fromSubgraph(
  ~manifest,
  ~schema,
  ~files=Dict.fromArray([("abis/Voting.json", votingAbi), ("abis/Locking.json", lockingAbi)]),
  ~mappings=Dict.fromArray([
    ("subgraph.yaml", manifest),
    ("schema.graphql", schema),
    ("abis/Voting.json", votingAbi),
    ("abis/Locking.json", lockingAbi),
    (
      "node_modules/@openzeppelin/subgraphs/package.json",
      `{"name":"@openzeppelin/subgraphs","version":"0.1.8-5"}`,
    ),
    (
      "node_modules/@openzeppelin/subgraphs/generated/schema.ts",
      `
import { Entity, Value, store } from "@graphprotocol/graph-ts";

export class Vote extends Entity {
  constructor(id: string) {
    super();
    this.set("id", Value.fromString(id));
  }

  save(): void {
    store.set("Vote", this.get("id")!.toString(), this);
  }
}
`,
    ),
    (
      "node_modules/@openzeppelin/subgraphs/src/datasources/voting.ts",
      `
import { ethereum } from "@graphprotocol/graph-ts";
import { Vote } from "../../generated/schema";

export function handleVoted(event: ethereum.Event): void {
  new Vote("vote-" + event.parameters[0].value.toBigInt().toString()).save();
}
`,
    ),
    (
      "src/locking.ts",
      `
import { Locked } from "../generated/locking/Locking";
import { Lock } from "../generated/schema";

export function handleLocked(event: Locked): void {
  let lock = new Lock("lock");
  lock.amount = event.params.amount;
  lock.save();
}
`,
    ),
  ]),
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("a dependency's mapping importing its own generated code", () => {
  it("leaves the project's generated/ where its own mappings import it", async (t) => {
    const indexer = createTestIndexer();

    await indexer.process({
      chains: {
        1: {
          simulate: [
            { contract: "Voting", event: "Voted", params: { weight: 3n } },
            { contract: "Locking", event: "Locked", params: { amount: 7n } },
          ],
        },
      },
    });

    t.expect({ votes: await indexer.Vote.getAll(), locks: await indexer.Lock.getAll() }).toEqual({
      votes: [{ id: "vote-3" }],
      locks: [{ id: "lock", amount: 7n }],
    });
  });
});
`,
)
