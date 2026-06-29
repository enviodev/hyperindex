open Vitest

// Regression coverage for SvmHyperSyncSource.getItemsOrThrow response
// parsing, driven through a mocked napi client (no network):
//   1. `instruction.block.time` must carry the slot's blockTime from the
//      response's blocks table (reported as arriving `undefined` downstream).
//   2. The query must spell out transaction/log columns when an event config
//      opts in — the server returns no rows for a table whose field list is
//      empty, so omitting them silently drops `instruction.transaction`.

let metaplexProgramId = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"
let chain = ChainMap.Chain.makeUnsafe(~chainId=0)

let blockTime = 1778064393
let slot = 417950033

let makeEventConfig = (
  ~selectedTransactionFields=[
    Internal.Signatures,
    FeePayer,
    Success,
    Err,
    Fee,
    ComputeUnitsConsumed,
    AccountKeys,
    RecentBlockhash,
    Version,
  ],
): Internal.svmInstructionEventConfig => {
  let selectedTransactionFields =
    Utils.Set.fromArray(selectedTransactionFields)->(
      Utils.magic: Utils.Set.t<Internal.svmTransactionField> => Utils.Set.t<string>
    )
  {
    id: "0x21",
    name: "CreateMetadataAccountV3",
    contractName: "TokenMetadata",
    isWildcard: false,
    filterByAddresses: false,
    dependsOnAddresses: true,
    handler: None,
    contractRegister: None,
    paramsRawEventSchema: %raw(`null`),
    simulateParamsSchema: %raw(`null`),
    startBlock: None,
    programId: metaplexProgramId->SvmTypes.Pubkey.fromStringUnsafe,
    discriminator: Some("0x21"),
    discriminatorByteLen: 1,
    includeLogs: false,
    selectedTransactionFields,
    transactionFieldMask: Svm.eventTransactionFieldMask(selectedTransactionFields),
    blockFieldMask: 0.,
    accountFilters: [],
    isInner: None,
    accounts: [],
    args: JSON.Null,
    definedTypes: JSON.Null,
  }
}

let mockResponse: SvmHyperSyncClient.ResponseTypes.queryResponse = {
  nextSlot: slot + 1,
  responseBytes: 0,
  data: {
    blocks: [
      {
        slot,
        blockhash: "99K5yyU2jLxLDeRCJ9YSSMy6VBJTNcnePWUH9uCHAWCB",
        blockTime,
      },
    ],
    instructions: [
      {
        slot,
        transactionIndex: 965,
        instructionAddress: [1],
        programId: metaplexProgramId,
        accounts: [],
        data: "0x21",
        d1: "0x21",
        isInner: false,
        isCommitted: true,
      },
    ],
    logs: [],
  },
}

let capturedQueries: array<SvmHyperSyncClient.query> = []

let mockClient: SvmHyperSyncClient.t = {
  getHeight: () => Promise.resolve(slot + 1000),
  get: (~query) => {
    capturedQueries->Array.push(query)
    // The real Rust client builds the store from raw transactions; the mock
    // returns an empty page (transaction materialisation is covered by the Rust
    // unit tests). This test asserts the item shape and the query columns.
    Promise.resolve((mockResponse, TransactionStore.make()))
  },
}

// The source captures its client at construction, so the mock addon only
// needs to be in place for the `make` call; restore the previous addon right
// after to avoid leaking the mock into other tests.
let makeSource = (~eventConfigs=[makeEventConfig()]) => {
  let prevAddon = Core.addonRef.contents
  Core.addonRef :=
    Some(
      {
        "SvmHypersyncClient": {
          "fromConfig": (_: SvmHyperSyncClient.cfg, _: string) => mockClient,
        },
      }->(Utils.magic: {..} => Core.addon),
    )
  let source = try SvmHyperSyncSource.make({
    chain,
    endpointUrl: "https://solana.hypersync.xyz",
    apiToken: None,
    eventConfigs,
    clientTimeoutMillis: 10_000,
  }) catch {
  | exn =>
    Core.addonRef := prevAddon
    throw(exn)
  }
  Core.addonRef := prevAddon
  source
}

let contractNameByAddress = Dict.fromArray([(metaplexProgramId, "TokenMetadata")])

describe("SvmHyperSyncSource.getItemsOrThrow (mocked client)", () => {
  Async.it("joins blockTime onto items and requests opted-in table columns", async t => {
    let source = makeSource()
    let eventConfig = makeEventConfig()

    let response = await source.getItemsOrThrow(
      ~fromBlock=slot - 10,
      ~toBlock=Some(slot + 10),
      ~addressesByContractName=Dict.fromArray([
        ("TokenMetadata", [metaplexProgramId->Address.unsafeFromString]),
      ]),
      ~contractNameByAddress,
      ~knownHeight=slot + 1000,
      ~partitionId="0",
      ~selection={
        eventConfigs: [(eventConfig :> Internal.eventConfig)],
        dependsOnAddresses: true,
      },
      ~retry=0,
      ~logger=Logging.createChild(~params={"test": "SvmHyperSyncSource"}),
    )

    let item = switch response.parsedQueueItems {
    | [Internal.Event({timestamp, blockNumber, payload})] =>
      let instruction = payload->(Utils.magic: Internal.eventPayload => Envio.svmInstruction)
      Some({
        "timestamp": timestamp,
        "blockNumber": blockNumber,
        "block": instruction.block,
      })
    | _ => None
    }

    t.expect({
      "item": item,
      "query": capturedQueries->Array.getUnsafe(0),
    }).toEqual({
      "item": Some({
        "timestamp": blockTime,
        "blockNumber": slot,
        "block": ({slot, time: blockTime, hash: ""}: Envio.svmInstructionBlock),
      }),
      // Default merge mode: requesting a table's columns opts the matched
      // result set into that join, so selections carry no include flags.
      "query": (
        {
          fromSlot: slot - 10,
          // Inclusive `toBlock` becomes exclusive `toSlot` on the wire (+1).
          toSlot: slot + 11,
          instructions: [{programId: [metaplexProgramId], d1: ["0x21"]}],
          fields: {
            block: [Slot, Blockhash, BlockTime],
            transaction: [
              Slot,
              TransactionIndex,
              Signatures,
              FeePayer,
              Success,
              Err,
              Fee,
              ComputeUnitsConsumed,
              AccountKeys,
              RecentBlockhash,
              Version,
            ],
          },
        }: SvmHyperSyncClient.query
      ),
    })
  })

  // `transactionIndex` is materialised from the store key (the instruction's
  // own index), not from a stored transaction record, so selecting it alone does
  // not need the transaction table fetched.
  Async.it(
    "does not fetch the transaction table when only transactionIndex is selected",
    async t => {
      let eventConfig = makeEventConfig(~selectedTransactionFields=[TransactionIndex])
      let source = makeSource(~eventConfigs=[eventConfig])

      let _ = await source.getItemsOrThrow(
        ~fromBlock=slot - 10,
        ~toBlock=Some(slot + 10),
        ~addressesByContractName=Dict.fromArray([
          ("TokenMetadata", [metaplexProgramId->Address.unsafeFromString]),
        ]),
        ~contractNameByAddress,
        ~knownHeight=slot + 1000,
        ~partitionId="0",
        ~selection={
          eventConfigs: [(eventConfig :> Internal.eventConfig)],
          dependsOnAddresses: true,
        },
        ~retry=0,
        ~logger=Logging.createChild(~params={"test": "SvmHyperSyncSource"}),
      )

      let query = capturedQueries->Array.getUnsafe(capturedQueries->Array.length - 1)
      t.expect(query.fields->Option.flatMap(fields => fields.transaction)).toEqual(None)
    },
  )
})
