open Vitest

// The user-facing entity shape declared in the schema string below —
// intentionally absent from the generated project schema.
type yamlToken = {
  id: string,
  owner: string,
}

type yamlTokenOps = {set: yamlToken => unit}
type yamlHandlerContext = {@as("YamlToken") yamlToken: yamlTokenOps}

describe("YAML-driven MockIndexer", () => {
  Async.it(
    "runs the indexer loop with a config parsed from user YAML instead of the generated one",
    async t => {
      let {config} = MockIndexerConfig.parseYaml(
        ~schema=`
type YamlToken {
  id: ID!
  owner: String!
}
`,
        `
name: yaml-driven
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer()
`,
      )

      let source = MockIndexer.Source.make([#getHeightOrThrow, #getItemsOrThrow], ~chain=#1337)
      let indexerMock = await MockIndexer.Indexer.make(
        ~config,
        ~chains=[{chain: #1337, sourceConfig: Config.CustomSources([source.source])}],
        ~shouldRollbackOnReorg=false,
      )
      await Utils.delay(0)

      source.resolveGetHeightOrThrow(300)
      await Utils.delay(0)
      await Utils.delay(0)

      source.resolveGetItemsOrThrow([
        {
          blockNumber: 5,
          logIndex: 0,
          handler: async args => {
            let context =
              args.context->(Utils.magic: MockIndexer.handlerContext => yamlHandlerContext)
            context.yamlToken.set({id: "token-1", owner: "0xabc"})
          },
        },
      ], ~latestFetchedBlockNumber=300)
      await indexerMock.getBatchWritePromise()

      let tokens: array<yamlToken> = await indexerMock.queryRaw(
        config.userEntitiesByName->Dict.getUnsafe("YamlToken"),
      )
      t.expect(tokens).toEqual([{id: "token-1", owner: "0xabc"}])
    },
  )
})
