open Vitest

let schema = `
type Token {
  id: Bytes!
  holders: [Holder!]! @derivedFrom(field: "token")
}
type Holder {
  id: ID!
  token: Token!
}
`

let configYaml = (~bytesType, ~rollback=false) =>
  `
name: bytes-id
bytes_type: ${bytesType}${rollback ? "\nrollback_on_reorg: true" : ""}
chains:
  - id: 1
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 0${rollback ? "\n    max_reorg_depth: 200" : ""}
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"
        events:
          - event: Transfer()
`

type token<'id> = {id: 'id}
type holder<'id> = {id: string, @as("token_id") tokenId: 'id}
type holderFilter<'id> = {token_id?: Envio.whereOperator<'id>}
type tokenOps<'id> = {
  set: token<'id> => unit,
  get: 'id => promise<option<token<'id>>>,
  deleteUnsafe: 'id => unit,
}
type holderOps<'id> = {
  set: holder<'id> => unit,
  getWhere: holderFilter<'id> => promise<array<holder<'id>>>,
}
type handlerContext<'id> = {
  @as("Token") token: tokenOps<'id>,
  @as("Holder") holder: holderOps<'id>,
}

type loaded<'id> = {
  token: option<token<'id>>,
  deleted: option<token<'id>>,
  holders: array<holder<'id>>,
}

// Sets two tokens and a holder pointing at the first, deletes the second by
// id, then in a later batch reads the survivors back from storage by id and
// through the foreign key.
let run = async (~indexer: IndexerRunner.t, ~source: MockSource.t, ~kept: 'id, ~dropped: 'id) => {
  source.resolveGetHeightOrThrow(10)
  await source.expectItemsQueries([
    {
      fromBlock: 0,
      toBlock: Unbounded,
      reply: Respond({
        items: [
          {
            blockNumber: 5,
            logIndex: 0,
            handler: async args => {
              let context =
                args.context->(Utils.magic: Internal.handlerContext => handlerContext<'id>)
              context.token.set({id: kept})
              context.token.set({id: dropped})
              context.holder.set({id: "h1", tokenId: kept})
              context.token.deleteUnsafe(dropped)
            },
          },
        ],
        latestFetchedBlockNumber: 5,
      }),
    },
  ])
  await indexer.getBatchWritePromise()

  let loaded = ref(None)
  await source.expectItemsQueries([
    {
      fromBlock: 6,
      toBlock: Unbounded,
      reply: Respond({
        items: [
          {
            blockNumber: 6,
            logIndex: 0,
            handler: async args => {
              let context =
                args.context->(Utils.magic: Internal.handlerContext => handlerContext<'id>)
              loaded :=
                Some({
                  token: await context.token.get(kept),
                  deleted: await context.token.get(dropped),
                  holders: await context.holder.getWhere({token_id: {_eq: kept}}),
                })
            },
          },
        ],
        latestFetchedBlockNumber: 10,
      }),
    },
  ])
  await indexer.getBatchWritePromise()

  let tokens: array<token<'id>> = await indexer.query("Token")
  let holders: array<holder<'id>> = await indexer.query("Holder")
  (loaded.contents, tokens, holders)
}

let rollbackScenario = (~bytesType) =>
  Scenario.make(~supervised=false, ~schema, ~configYaml=configYaml(~bytesType, ~rollback=true))

let tokenItem = (~block, handler): MockSource.itemMock => {
  blockNumber: block,
  logIndex: 0,
  handler: async args =>
    await handler(args.context->(Utils.magic: Internal.handlerContext => handlerContext<'id>)),
}

// Block 101 sets `restored`; block 102 sets `removed` and deletes `restored`.
// Reorging block 102 away has to restore one id from history and remove the
// other, both keyed on the Bytes id read back from storage.
let rollback = async (
  ~indexer: IndexerRunner.t,
  ~source: MockSource.t,
  ~restored: 'id,
  ~removed: 'id,
) => {
  await Scenario.enterReorgThreshold(~indexer, ~source, ~fromBlock=0)
  await source.expectItemsQueries([
    {
      fromBlock: 101,
      reply: Respond({
        items: [tokenItem(~block=101, async context => context.token.set({id: restored}))],
        latestFetchedBlockNumber: 101,
        latestFetchedBlockHash: "0x0101",
      }),
    },
  ])
  await indexer.getBatchWritePromise()
  await source.expectItemsQueries([
    {
      fromBlock: 102,
      reply: Respond({
        items: [
          tokenItem(~block=102, async context => {
            context.token.set({id: removed})
            context.token.deleteUnsafe(restored)
          }),
        ],
        latestFetchedBlockNumber: 102,
        latestFetchedBlockHash: "0x0102",
      }),
    },
  ])
  await indexer.getBatchWritePromise()
  let beforeReorg: array<token<'id>> = await indexer.query("Token")

  await source.expectItemsQueries([
    {
      coversBlock: 103,
      reply: Respond({
        items: [],
        prevRangeLastBlock: {blockNumber: 102, blockHash: "0x102a"},
      }),
    },
    {partitionId: "0", reply: LeavePending},
  ])
  await source.expectBlockHashLookup({
    blockNumbers: [100, 101],
    reply: [
      {blockNumber: 100, blockHash: "0x0100", blockTimestamp: 100},
      {blockNumber: 101, blockHash: "0x0101", blockTimestamp: 101},
    ],
  })
  await indexer.getRollbackReadyPromise()
  // The rollback diff is written with the next batch.
  await source.expectItemsQueries([
    {
      coversBlock: 102,
      reply: Respond({
        items: [],
        latestFetchedBlockNumber: 102,
        latestFetchedBlockHash: "0x0102",
      }),
    },
  ])
  await indexer.getBatchWritePromise()
  await indexer.waitUntilIdle()

  let afterReorg: array<token<'id>> = await indexer.query("Token")
  await indexer.stop()
  (beforeReorg, afterReorg)
}

let reorgMethods: array<MockSource.method> = [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]

@val @scope("Buffer") external bufferFrom: array<int> => Uint8Array.t = "from"

let tokenIds = (tokens: array<token<Uint8Array.t>>) =>
  tokens->Array.map(token => token.id)->Array.toSorted(Utils.Bytes.compare)

describe("Bytes entity id", () => {
  Scenario.make(
    ~schema,
    ~configYaml=configYaml(~bytesType="hex"),
  )->Scenario.it(
    "round-trips a hex Bytes id and the foreign key referencing it",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let kept = "0xaa01"
      t.expect(await run(~indexer, ~source=source(1), ~kept, ~dropped="0xbb02")).toEqual((
        Some({token: Some({id: kept}), deleted: None, holders: [{id: "h1", tokenId: kept}]}),
        [{id: kept}],
        [{id: "h1", tokenId: kept}],
      ))
    },
  )

  Scenario.make(
    ~schema,
    ~configYaml=configYaml(~bytesType="uint8array"),
  )->Scenario.it(
    "round-trips a Uint8Array Bytes id and the foreign key referencing it",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let kept = Uint8Array.fromArray([0xaa, 0x01])
      t.expect(
        await run(~indexer, ~source=source(1), ~kept, ~dropped=Uint8Array.fromArray([0xbb, 0x02])),
      ).toEqual((
        Some({token: Some({id: kept}), deleted: None, holders: [{id: "h1", tokenId: kept}]}),
        [{id: kept}],
        [{id: "h1", tokenId: kept}],
      ))
    },
  )

  // https://github.com/enviodev/hyperindex/pull/1787#discussion_r4422855235
  // `Buffer` stringifies by decoding UTF-8, so `[0xaa]`, `[0xbb]` and `[0xcc]`
  // would all key as "�" if an id were keyed by `String`.
  Scenario.make(
    ~schema,
    ~configYaml=configYaml(~bytesType="uint8array"),
  )->Scenario.it(
    "keys a Buffer id by its bytes, the same as a plain Uint8Array",
    ~sources=[{chain: 1}],
    async (~t, ~indexer, ~source) => {
      let source = source(1)
      source.resolveGetHeightOrThrow(10)
      let inMemory = ref([])
      let fromStorage = ref([])
      await source.expectItemsQueries([
        {
          fromBlock: 0,
          toBlock: Unbounded,
          reply: Respond({
            items: [
              tokenItem(
                ~block=5,
                async context => {
                  context.token.set({id: bufferFrom([0xaa])})
                  context.token.set({id: bufferFrom([0xbb])})
                  inMemory :=
                    (
                      await Promise.all([
                        context.token.get(Uint8Array.fromArray([0xaa])),
                        context.token.get(Uint8Array.fromArray([0xbb])),
                      ])
                    )->Array.map(Option.isSome)
                },
              ),
            ],
            latestFetchedBlockNumber: 5,
          }),
        },
      ])
      await indexer.getBatchWritePromise()
      await source.expectItemsQueries([
        {
          fromBlock: 6,
          toBlock: Unbounded,
          reply: Respond({
            items: [
              tokenItem(
                ~block=6,
                async context => {
                  fromStorage :=
                    (
                      await Promise.all([
                        context.token.get(bufferFrom([0xaa])),
                        context.token.get(bufferFrom([0xcc])),
                      ])
                    )->Array.map(Option.isSome)
                },
              ),
            ],
            latestFetchedBlockNumber: 10,
          }),
        },
      ])
      await indexer.getBatchWritePromise()

      let tokens: array<token<Uint8Array.t>> = await indexer.query("Token")
      t.expect((inMemory.contents, fromStorage.contents, tokens->tokenIds)).toEqual((
        [true, true],
        [true, false],
        [Uint8Array.fromArray([0xaa]), Uint8Array.fromArray([0xbb])],
      ))
    },
  )

  rollbackScenario(~bytesType="hex")->Scenario.it(
    "rolls back a hex Bytes id",
    ~sources=[{chain: 1, methods: reorgMethods}],
    async (~t, ~indexer, ~source) => {
      let restored = "0xaa01"
      let removed = "0xbb02"
      t.expect(await rollback(~indexer, ~source=source(1), ~restored, ~removed)).toEqual((
        [{id: removed}],
        [{id: restored}],
      ))
    },
  )

  rollbackScenario(~bytesType="uint8array")->Scenario.it(
    "rolls back a Uint8Array Bytes id",
    ~sources=[{chain: 1, methods: reorgMethods}],
    async (~t, ~indexer, ~source) => {
      let restored = Uint8Array.fromArray([0xaa, 0x01])
      let removed = Uint8Array.fromArray([0xbb, 0x02])
      t.expect(await rollback(~indexer, ~source=source(1), ~restored, ~removed)).toEqual((
        [{id: removed}],
        [{id: restored}],
      ))
    },
  )

  it("still rejects an id type outside the supported set", t => {
    t->toThrowErrorEqual(
      () =>
        InternalTestIndexer.fromUserApi(
          ~schema=`type Thing { id: Float! }`,
          ~configYaml=configYaml(~bytesType="hex"),
        )->ignore,
      "schema.graphql:1:1: The 'id' field on entity Thing has unsupported type 'Float'. An entity id must be one of: ID, String, Int, BigInt, Bytes.",
    )
  })
})
