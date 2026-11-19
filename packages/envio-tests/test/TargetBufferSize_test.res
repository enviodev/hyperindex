open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: target-buffer-size
rollback_on_reorg: false
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Gravatar {
  id: ID!
}
`,
)

describe("Target buffer size", () => {
  scenario->Scenario.it(
    "defaults to 300,000 items across the indexer",
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
    async (~t, ~indexer, ~source) => {
      await Scenario.resolveInitialHeight(~source=source(1337), ~head=100)
      t.expect(
        (await indexer.metric("envio_indexing_target_buffer_size"))->Array.map(
          ({value}: IndexerRunner.metric) => value,
        ),
      ).toEqual(["300000"])
    },
  )
})
