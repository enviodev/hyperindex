open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: stalled-teardown
contracts:
  - name: Token
    events:
      - event: Transfer()
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
`,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
)

let gate = MockSource.Gate.make()

// A body that fails while it holds a write stalled never gets to release it.
// Teardown has to report that failure rather than wait on the write forever and
// surface as a bare suite timeout.
Async.it("reports a failing body while a write it stalled is still pending", async t => {
  let failure = try {
    await scenario->Scenario.run(
      ~sources=[{chain: 1, methods: [#getHeightOrThrow, #getItemsOrThrow]}],
      ~mapStorage=storage => {
        ...storage,
        writeBatch: (
          ~batch,
          ~rollback,
          ~config,
          ~allEntities,
          ~updatedEffectsCache,
          ~updatedEntities,
          ~registeredAddresses,
          ~chainMetaData,
          ~onWrite,
        ) =>
          gate.wait()->Promise.then(() =>
            storage.writeBatch(
              ~batch,
              ~rollback,
              ~config,
              ~allEntities,
              ~updatedEffectsCache,
              ~updatedEntities,
              ~registeredAddresses,
              ~chainMetaData,
              ~onWrite,
            )
          ),
      },
      async (~indexer as _, ~source) => {
        let mock = source(1)
        mock.resolveGetHeightOrThrow(100)
        await mock.expectItemsQueries([
          {
            fromBlock: 1,
            reply: Respond({items: [{blockNumber: 5, logIndex: 0}], latestFetchedBlockNumber: 100}),
          },
        ])
        await Scenario.waitUntil(() => gate.entered.contents > 0, ~message="the write stalls")
        JsError.throwWithMessage("the body failed")
      },
    )
    None
  } catch {
  | JsExn(exn) => exn->JsExn.message
  }
  gate.release()
  t.expect(failure).toEqual(Some("the body failed"))
})
