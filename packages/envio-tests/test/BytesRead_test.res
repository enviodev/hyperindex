open Vitest

// Bytes a handler loads are copied out of the memory the read was decoded in,
// once for the whole column, so each value holds on to the bytes its result
// carried rather than everything that read had room for.

let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: bytes-read
bytes_type: uint8array
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Blob {
  id: ID!
  kind: String! @index
  data: Bytes!
}
`,
)

type blob = {id: string, kind: string, data: Uint8Array.t}
type blobOps = {
  set: blob => unit,
  getWhere: {"kind": {"_eq": string}} => promise<array<blob>>,
}
type handlerContext = {@as("Blob") blob: blobOps}

let inHandler = (~block, run: handlerContext => promise<unit>): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args =>
    await args.context->(Utils.magic: Internal.handlerContext => handlerContext)->run,
}

describe("Bytes read back into a handler", () => {
  scenario->Scenario.it("keep only the bytes their result held", ~sources=[{chain: 1}], async (
    ~t,
    ~indexer,
    ~source,
  ) => {
    let source = source(1)
    await Utils.delay(0)
    await Scenario.resolveInitialHeight(~t, ~source, ~head=100)
    source.resolveGetItemsOrThrow(
      [
        inHandler(
          ~block=1,
          async context => {
            context.blob.set({id: "a", kind: "k", data: Uint8Array.fromArray([0xde, 0xad])})
            context.blob.set({id: "b", kind: "k", data: Uint8Array.fromArray([0xbe, 0xef])})
          },
        ),
      ],
      ~filter=MockSource.coveringBlock(1),
      ~latestFetchedBlockNumber=1,
    )
    await indexer.getBatchWritePromise()

    // Restarted, so the values come from Postgres rather than memory.
    source.setAutoHeight(100)
    let restarted = await indexer.restart()
    let read = ref([])
    source.resolveGetItemsOrThrow(
      [
        inHandler(
          ~block=2,
          async context =>
            read :=
              (await context.blob.getWhere({"kind": {"_eq": "k"}}))
              ->Array.toSorted((a, b) => String.compare(a.id, b.id))
              ->Array.map(
                blob => (
                  blob.data->TypedArray.toString,
                  blob.data->TypedArray.buffer->ArrayBuffer.byteLength,
                ),
              ),
        ),
      ],
      ~filter=MockSource.coveringBlock(2),
      ~latestFetchedBlockNumber=2,
    )
    await restarted.getBatchWritePromise()

    t.expect(read.contents).toEqual([("222,173", 4), ("190,239", 4)])
  })
})
