open Vitest

// https://github.com/enviodev/hyperindex/pull/1598
let scenario = Scenario.make(
  ~configYaml=`
name: entity-nullable-bigint
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    max_reorg_depth: 200
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Position {
  id: ID!
  withdrawnValue: BigInt
  sharesReceived: BigDecimal
  reason: String
}
`,
)

type position = {
  id: string,
  withdrawnValue: Nullable.t<bigint>,
  sharesReceived: Nullable.t<BigDecimal.t>,
  reason: Nullable.t<string>,
}
type positionOps = {set: position => unit}
type handlerContext = {@as("Position") position: positionOps}

type loadedPosition = {
  id: string,
  withdrawnValue: option<bigint>,
  sharesReceived: option<BigDecimal.t>,
  reason: option<string>,
}

let setPosition = (position, ~indexer: IndexerRunner.t, ~source: MockSource.t) => {
  source.resolveGetHeightOrThrow(300)
  source.resolveGetItemsOrThrow(
    [
      {
        blockNumber: 100,
        logIndex: 0,
        handler: async args => {
          let context = args.context->(Utils.magic: Internal.handlerContext => handlerContext)
          context.position.set(position)
        },
      },
    ],
    ~latestFetchedBlockNumber=100,
  )
  indexer.getBatchWritePromise()
}

let rec errorMessage = exn =>
  switch exn->Utils.prettifyExn {
  | Persistence.StorageError({message, reason}) => `${message}: ${reason->errorMessage}`
  | exn => exn->(Utils.magic: exn => {"message": string})->(e => e["message"])
  }

let itWritesPosition = (name, position, ~expected) => {
  let errors = []
  scenario->Scenario.it(
    name,
    ~sources=[{chain: 1337, methods: [#getHeightOrThrow, #getItemsOrThrow, #getBlockHashes]}],
    ~onError=errHandler => errors->Array.push(errHandler.exn->errorMessage)->ignore,
    async (~t, ~indexer, ~source) => {
      await setPosition(position, ~indexer, ~source=source(1337))

      let entities: array<loadedPosition> = await indexer.query("Position")
      t.expect((errors->Array.copy, entities)).toEqual(([], [expected]))
    },
  )
}

describe("Nullable entity fields written to storage", () => {
  itWritesPosition(
    "writes nullable fields the handler left unset",
    {
      id: "unset",
      withdrawnValue: Nullable.undefined,
      sharesReceived: Nullable.undefined,
      reason: Nullable.undefined,
    },
    ~expected={id: "unset", withdrawnValue: None, sharesReceived: None, reason: None},
  )

  itWritesPosition(
    "writes nullable fields the handler set to null",
    {
      id: "null",
      withdrawnValue: Nullable.null,
      sharesReceived: Nullable.null,
      reason: Nullable.null,
    },
    ~expected={id: "null", withdrawnValue: None, sharesReceived: None, reason: None},
  )
})
