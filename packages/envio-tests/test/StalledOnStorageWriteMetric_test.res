open Vitest

let scenario = Scenario.make(
  ~configYaml=`
name: stalled-on-storage-write-metric
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
type Tally {
  id: ID!
}
`,
)

type tally = {id: string}
type tallyOps = {set: tally => unit}
type handlerContext = {@as("Tally") tally: tallyOps}

let setTally = (id, args: Internal.handlerArgs) =>
  (args.context->(Utils.magic: Internal.handlerContext => handlerContext)).tally.set({id: id})

// The first write of an entity waits on this, once the test sets it.
let holdWrite: ref<option<unit => promise<unit>>> = ref(None)

describe("envio_processing_stalled_on_storage_write_seconds", () => {
  scenario->Scenario.it(
    "times processing held back by a write by the run's clock",
    ~sources=[{chain: 1}],
    ~inMemoryObjectsTarget=1.,
    ~mapStorage=storage => {
      ...storage,
      writeBatch: async (
        ~batch,
        ~rollback,
        ~config,
        ~updatedEffectsCache,
        ~updatedEntities,
        ~registeredAddresses,
        ~chainMetaData,
        ~onWrite,
      ) => {
        switch holdWrite.contents {
        | Some(hold) if updatedEntities->Utils.Array.notEmpty =>
          holdWrite := None
          await hold()
        | _ => ()
        }
        await storage.writeBatch(
          ~batch,
          ~rollback,
          ~config,
          ~updatedEffectsCache,
          ~updatedEntities,
          ~registeredAddresses,
          ~chainMetaData,
          ~onWrite,
        )
      },
    },
    async (~t, ~indexer, ~source) => {
      holdWrite := Some(() => indexer.delay(50))
      let secondHandled = ref(false)
      let mock = source(1)
      mock.resolveGetHeightOrThrow(300)
      await mock.expectItemsQueries([
        {
          fromBlock: 1,
          reply: Respond({
            items: [{blockNumber: 5, logIndex: 1, handler: async args => setTally("first", args)}],
            latestFetchedBlockNumber: 100,
          }),
        },
      ])
      await mock.expectItemsQueries([
        {
          fromBlock: 101,
          reply: Respond({
            items: [
              {
                blockNumber: 150,
                logIndex: 1,
                handler: async args => {
                  setTally("second", args)
                  secondHandled := true
                },
              },
            ],
            latestFetchedBlockNumber: 200,
          }),
        },
      ])
      // Real time: handlers run off the clock.
      await Scenario.waitUntil(() => secondHandled.contents, ~message="the second batch")
      // The second batch is queued behind the held write, so the third, a batch
      // of its own, has to wait for it.
      await mock.expectItemsQueries([
        {
          fromBlock: 201,
          reply: Respond({
            items: [
              {blockNumber: 250, logIndex: 1, handler: async args => setTally("third", args)},
            ],
            latestFetchedBlockNumber: 300,
          }),
        },
      ])
      await indexer.advanceTime(50)
      await indexer.getBatchWritePromise()
      t.expect(await indexer.metric("envio_processing_stalled_on_storage_write_seconds")).toEqual([
        {value: "0.05", labels: dict{}},
      ])
    },
  )
})
