open Vitest

// https://github.com/enviodev/hyperindex/issues/1678
// Contract import maps a tuple param to a Json field and assigns the decoded
// value to it as is, so every integer inside arrives as a bigint. The entity
// row goes through the UNNEST insert and its history row through INSERT
// VALUES, which binds each value on its own.
let scenario = Scenario.make(
  ~configYaml=`
name: json-bigint
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0
    contracts:
      - name: WXTZ
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: EnforcedOptionSet((uint32,uint16,bytes)[] _enforcedOptions)
`,
  ~schema=`
type WXTZ_EnforcedOptionSet {
  id: ID!
  _enforcedOptions: Json!
}
`,
)

type enforcedOptionSet = {id: string, _enforcedOptions: unknown}
type handlerContext = {
  @as("WXTZ_EnforcedOptionSet") enforcedOptionSet: {set: enforcedOptionSet => unit},
}

describe("Json field holding bigints", () => {
  scenario->Scenario.it("stores them as decimal strings", ~sources=[{chain: 1}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let source = source(1)
    source.resolveGetHeightOrThrow(10)

    source.resolveGetItemsOrThrow(
      [
        {
          blockNumber: 5,
          logIndex: 0,
          handler: async args => {
            let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
            context.enforcedOptionSet.set({
              id: "1",
              _enforcedOptions: %raw(`[
                [30101n, 1n, "0x0003"],
                [30110n, 115792089237316195423570985008687907853269984665640564039457584007913129639935n, "0x"],
              ]`),
            })
          },
        },
      ],
      ~latestFetchedBlockNumber=10,
    )
    await indexer.getBatchWritePromise()

    let stored = {
      id: "1",
      _enforcedOptions: %raw(`[
        ["30101", "1", "0x0003"],
        ["30110", "115792089237316195423570985008687907853269984665640564039457584007913129639935", "0x"],
      ]`),
    }
    t.expect((
      await (indexer.query("WXTZ_EnforcedOptionSet"): promise<array<enforcedOptionSet>>),
      await (
        indexer.queryHistory("WXTZ_EnforcedOptionSet"): promise<array<Change.t<enforcedOptionSet>>>
      ),
    )).toEqual((
      [stored],
      [Set({checkpointId: 1n, entityId: "1"->EntityId.unsafeOfString, entity: stored})],
    ))

    switch IndexerRunner.selectedBackend {
    | #postgres => ()
    | #clickhouse =>
      let database = TestClickHouse.currentDatabase()
      let rows = await TestClickHouse.query(
        `SELECT id, _enforcedOptions FROM \`${database}\`.\`WXTZ_EnforcedOptionSet\` FORMAT JSONEachRow`,
      )
      t.expect(rows->String.trim->JSON.parseOrThrow).toEqual(
        %raw(`{
          id: "1",
          _enforcedOptions: '[["30101","1","0x0003"],["30110","115792089237316195423570985008687907853269984665640564039457584007913129639935","0x"]]',
        }`),
      )
    }
  })
})
