open Vitest

// Two scenarios in one file, each with its own config, schema and handlers.
// The registration cycle is process-global, so the second scenario's handlers
// used to register into the first scenario's registration — which knows
// nothing about the second one's chains or contracts.

let tokenScenario = Scenario.make(
  ~configYaml=`
name: token-scenario
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer(address indexed from, address indexed to, uint256 value)
`,
  ~schema=`
type Account {
  id: ID!
  balance: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ context }) => {
  context.Account.set({ id: "unreachable", balance: 1n });
});
`,
)

let nftScenario = Scenario.make(
  ~configYaml=`
name: nft-scenario
chains:
  - id: 4242
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: Nft
        address: "0x0000000000000000000000000000000000000002"
        events:
          - event: Minted(address indexed owner, uint256 tokenId)
`,
  ~schema=`
type Owner {
  id: ID!
  count: BigInt!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onEvent({ contract: "Nft", event: "Minted" }, async ({ context }) => {
  context.Owner.set({ id: "unreachable", count: 1n });
});
`,
)

type account = {id: string, balance: bigint}
type owner = {id: string, count: bigint}

type accountOps = {set: account => unit}
type accountContext = {@as("Account") account: accountOps}
type ownerOps = {set: owner => unit}
type ownerContext = {@as("Owner") owner: ownerOps}

describe("Scenario isolation", () => {
  Async.it("runs the first scenario against its own config and schema", async t => {
    await tokenScenario->Scenario.run(
      ~sources=[{chain: 1337}],
      async (~indexer, ~source) => {
        let source = source(1337)
        source.resolveGetHeightOrThrow(10)

        source.resolveGetItemsOrThrow(
          [
            {
              blockNumber: 5,
              logIndex: 0,
              handler: async args => {
                let context = args.context->(Utils.magic: Internal.handlerContext => accountContext)
                context.account.set({id: "token-1", balance: 7n})
              },
            },
          ],
          ~latestFetchedBlockNumber=10,
        )
        await indexer.getBatchWritePromise()

        let accounts: array<account> = await indexer.query("Account")
        t.expect(accounts).toEqual([{id: "token-1", balance: 7n}])
      },
    )
  })

  // Reaching the assertion at all means this scenario's handlers registered
  // against this scenario's config: `Nft` exists in no other scenario, so a
  // registration leaked from the first one throws while importing them.
  Async.it("runs the second scenario against its own config and schema", async t => {
    await nftScenario->Scenario.run(
      ~sources=[{chain: 4242}],
      async (~indexer, ~source) => {
        let source = source(4242)
        source.resolveGetHeightOrThrow(10)

        source.resolveGetItemsOrThrow(
          [
            {
              blockNumber: 5,
              logIndex: 0,
              handler: async args => {
                let context = args.context->(Utils.magic: Internal.handlerContext => ownerContext)
                context.owner.set({id: "owner-1", count: 3n})
              },
            },
          ],
          ~latestFetchedBlockNumber=10,
        )
        await indexer.getBatchWritePromise()

        let owners: array<owner> = await indexer.query("Owner")
        t.expect(owners).toEqual([{id: "owner-1", count: 3n}])
      },
    )
  })
})
