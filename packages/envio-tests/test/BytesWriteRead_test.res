open Vitest

// Under `bytes_type: uint8array` a Bytes field crosses every storage boundary as
// raw bytes: the Postgres row is a bytea the handler reads back as a Uint8Array,
// a filter binds the value against that column, and the ClickHouse String
// column holds the same bytes.
let scenario = Scenario.make(
  ~configYaml=`
name: bytes-write-read
bytes_type: uint8array
chains:
  - id: 1
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
type Blob {
  id: ID!
  data: Bytes!
  optData: Bytes
  chunks: [Bytes!]!
  tag: Bytes! @index
}
`,
)

type blob = {
  id: string,
  data: Uint8Array.t,
  optData: option<Uint8Array.t>,
  chunks: array<Uint8Array.t>,
  tag: Uint8Array.t,
}
type blobFilter = {tag?: Envio.whereOperator<Uint8Array.t>}
type blobOps = {set: blob => unit, getWhere: blobFilter => promise<array<blob>>}
type handlerContext = {@as("Blob") blob: blobOps}

let first = {
  id: "1",
  data: Uint8Array.fromArray([0, 1, 254, 255]),
  optData: Some(Uint8Array.fromArray([0x5c, 0x78, 0x27, 0x22])),
  chunks: [Uint8Array.fromArray([1, 2]), Uint8Array.fromLength(0), Uint8Array.fromArray([3])],
  tag: Uint8Array.fromArray([0xaa]),
}
let second = {
  id: "2",
  data: Uint8Array.fromLength(0),
  optData: None,
  chunks: [],
  tag: Uint8Array.fromArray([0xbb]),
}

describe("Bytes as Uint8Array", () => {
  scenario->Scenario.it(
    "writes raw bytes and reads them back as Uint8Array",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(10)

      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 5,
            logIndex: 0,
            handler: async args => {
              let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
              context.blob.set(first)
              context.blob.set(second)
            },
          },
        ],
        ~latestFetchedBlockNumber=5,
      )
      await indexer.getBatchWritePromise()

      let queried = Dict.make()
      source.resolveGetItemsOrThrow(
        [
          {
            blockNumber: 6,
            logIndex: 0,
            handler: async args => {
              let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
              queried->Dict.set("eq", await context.blob.getWhere({tag: {_eq: first.tag}}))
              queried->Dict.set(
                "in",
                await context.blob.getWhere({
                  tag: {_in: [second.tag, Uint8Array.fromArray([0xcc])]},
                }),
              )
            },
          },
        ],
        ~latestFetchedBlockNumber=10,
      )
      await indexer.getBatchWritePromise()

      t.expect((
        await (indexer.query("Blob"): promise<array<blob>>),
        queried,
        await (indexer.queryHistory("Blob"): promise<array<Change.t<blob>>>),
      )).toEqual((
        [first, second],
        Dict.fromArray([("eq", [first]), ("in", [second])]),
        [
          Set({checkpointId: 1n, entityId: "1"->EntityId.unsafeOfString, entity: first}),
          Set({checkpointId: 1n, entityId: "2"->EntityId.unsafeOfString, entity: second}),
        ],
      ))

      switch IndexerRunner.selectedBackend {
      | #postgres => ()
      | #clickhouse =>
        let database = TestClickHouse.currentDatabase()
        let rows = await TestClickHouse.query(
          `SELECT id, hex(data) AS data, hex(optData) AS optData, arrayMap(x -> hex(x), chunks) AS chunks, hex(tag) AS tag FROM \`${database}\`.\`Blob\` ORDER BY id FORMAT JSONEachRow`,
        )
        t.expect(
          rows->String.trim->String.split("\n")->Array.map(row => row->JSON.parseOrThrow),
        ).toStrictEqual(
          %raw(`[
            { id: "1", data: "0001FEFF", optData: "5C782722", chunks: ["0102", "", "03"], tag: "AA" },
            { id: "2", data: "", optData: null, chunks: [], tag: "BB" },
          ]`),
        )
      }
    },
  )
})
