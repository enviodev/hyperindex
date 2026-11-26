open Vitest

// The SVM HyperSync source as a whole: the selection and slot range it sends,
// the items a page builds by registration index, the registration inputs that
// cross the boundary once at construction, and its height stream.

let metaplexProgramId = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s"
let chainId = 0->ChainId.fromInt

let blockTime = 1778064393
let slot = 417950033
let blockHash = "99K5yyU2jLxLDeRCJ9YSSMy6VBJTNcnePWUH9uCHAWCB"

let makeEventConfig = (
  ~selectedBlockFields: array<Internal.svmBlockField>=[],
  ~selectedTransactionFields: array<Internal.svmTransactionField>=[],
): Internal.svmInstructionEventConfig => {
  {
    name: "CreateMetadataAccountV3",
    contractName: "TokenMetadata",
    paramsRawEventSchema: %raw(`null`),
    simulateParamsSchema: %raw(`null`),
    programId: metaplexProgramId->SvmTypes.Pubkey.fromStringUnsafe,
    discriminator: Some("0x21"),
    fieldSelection: Internal.makeFieldSelection(
      ~blockFields=Utils.Set.fromArray(
        selectedBlockFields->(Utils.magic: array<Internal.svmBlockField> => array<string>),
      ),
      ~transactionFields=Utils.Set.fromArray(
        selectedTransactionFields->(
          Utils.magic: array<Internal.svmTransactionField> => array<string>
        ),
      ),
      ~blockMaskFn=Svm.eventBlockFieldMask,
      ~transactionMaskFn=Svm.eventTransactionFieldMask,
    ),
    accounts: [],
    args: JSON.Null,
    definedTypes: JSON.Null,
  }
}

let makeReg = (~eventConfig=makeEventConfig(), ~where=None, ~index=0) => {
  let reg = EventConfigBuilder.buildSvmOnEventRegistration(
    ~eventConfig,
    ~isWildcard=false,
    ~handler=None,
    ~contractRegister=None,
    ~where,
  )
  {...reg, Internal.index}
}

let mockItem: SvmEventItem.item = {
  slot,
  transactionIndex: 965,
  path: [1],
  programId: metaplexProgramId,
  accounts: [],
  data: Uint8Array.fromArray([0x21]),
  isInner: false,
  args: Nullable.undefined,
  logs: Nullable.undefined,
}

// The chain's address index.
let addressStore = TestAddresses.storeOf(
  ~contracts=[{name: "TokenMetadata", startBlock: None, dependsOnAddresses: true}],
  ~addresses=[
    {
      address: metaplexProgramId->Address.unsafeFromString,
      contractName: "TokenMetadata",
      registrationBlock: -1,
    },
  ],
  ~ecosystem=Svm,
)

let makeSource = (
  ~onEventRegistrations=[makeReg()],
  ~url="https://solana.hypersync.xyz",
  ~apiToken=IndexerEnv.read().envioApiToken,
) =>
  TestSources.hyperSync(
    ~url,
    ~ecosystem=Svm,
    ~apiToken,
    ~chainBuffer=TestChainBuffer.forChain(~ecosystem=Svm, ~onEventRegistrations, ~addressStore),
  )

// The Metaplex program, registered under the TokenMetadata program name.
let programSet = addressStore->AddressStore.makeSet(~contractName="TokenMetadata")

let fetch = async (
  source: Source.t,
  ~reg: Internal.svmOnEventRegistration,
  ~fromBlock,
  ~toBlock,
  ~reorgableFrom=None,
) =>
  switch (
    await source.getItems(
      ~reorgableFrom,
      ~fromBlock,
      ~toBlock=Some(toBlock),
      ~addressSet=programSet,
      ~knownHeight=toBlock + 1000,
      ~partitionId="0",
      ~selection={
        onEventRegistrations: [(reg :> Internal.onEventRegistration)],
        dependsOnAddresses: true,
        onBlockRegistrations: [],
        onTransactionRegistrations: [],
      },
      ~retry=0,
    )
  ).result {
  | Ok(itemsPage) => itemsPage
  | Error(failure) => JsError.throwWithMessage(failure->Source.failureMessage)
  }

describe("SvmHyperSyncSource.getItems (live)", () => {
  Async.itWithOptions(
    "asks for the inclusive slot range and builds items by registration index",
    {retry: 3},
    async t => {
      let reg = makeReg()
      let source = makeSource(~onEventRegistrations=[reg])
      let {page, latestFetchedBlockNumber, knownHeight} = await source->fetch(
        ~reg,
        ~fromBlock=slot - 10,
        ~toBlock=slot + 10,
      )
      let items = await page->TestChainBuffer.itemsOf(
        ~onEventRegistrations=[(reg :> Internal.onEventRegistration)],
        ~addressStore,
        ~ecosystem=Svm,
      )

      t.expect({
        "latestFetchedBlockNumber": latestFetchedBlockNumber,
        "knownHeight": knownHeight,
        "items": items->Array.map(
          item =>
            switch item {
            | Internal.Event({blockNumber, transactionIndex, ?orderPath, onEventRegistration}) => (
                blockNumber,
                transactionIndex,
                orderPath,
                onEventRegistration.index,
              )
            | Internal.Block(_) | Internal.Transaction(_) =>
              JsError.throwWithMessage("Expected an instruction item")
            },
        ),
      }).toEqual({
        "latestFetchedBlockNumber": slot + 10,
        // An SVM page reports no height of its own.
        "knownHeight": None,
        // The window's one CreateMetadataAccountV3 call on mainnet.
        "items": [(slot, 228, Some([4]), 0)],
      })
    },
  )

  it("builds an instruction item for its registration", t => {
    let reg = makeReg()
    let item = switch mockItem->SvmEventItem.toInternalItem(
      ~onEventRegistration=(reg :> Internal.onEventRegistration),
      ~chainId,
    ) {
    | Internal.Event({
        blockNumber,
        logIndex,
        orderPath,
        transactionIndex,
        payload,
        onEventRegistration,
      }) =>
      let instruction = payload->(Utils.magic: Internal.eventPayload => Envio.svmInstruction)
      Some({
        "blockNumber": blockNumber,
        // A slot orders by (transactionIndex, path); the pair
        // rides the item as (logIndex, orderPath).
        "logIndex": logIndex,
        "orderPath": orderPath,
        "transactionIndex": transactionIndex,
        // `block` is omitted here; it's materialised from the store at batch
        // prep, which this test doesn't run.
        "block": instruction.block,
        "args": instruction.args,
        "accounts": instruction.accounts,
        "usesSourceRegistration": onEventRegistration === (reg :> Internal.onEventRegistration),
      })
    | _ => None
    }

    t.expect(item).toEqual(
      Some({
        "blockNumber": slot,
        "logIndex": 965,
        "orderPath": [1],
        "transactionIndex": 965,
        "block": None,
        "args": None,
        "accounts": None,
        "usesSourceRegistration": true,
      }),
    )
  })
})

describe("ChainRegistrations.Svm", () => {
  // The whole registration set crosses the boundary once at construction,
  // grouped under the config instruction each registration was built from:
  // selections, field unions, decoders, and routing derive from it in Rust.
  it("groups registrations under their program and instruction", t => {
    let swap = makeEventConfig()
    let other = {...makeEventConfig(), name: "UpdateMetadataAccountV2", discriminator: Some("0x0f")}
    let programs = ChainRegistrations.Svm.fromOnEventRegistrations([
      makeReg(~eventConfig=swap, ~index=0),
      makeReg(~eventConfig=other, ~index=1),
      makeReg(~eventConfig=swap, ~index=2),
    ])
    let registration = index => {
      ChainRegistrations.Svm.index,
      isWildcard: false,
      startBlock: None,
      accountFilters: [],
      transactionFields: [],
      blockFields: [],
      accountActivityFields: [],
      logFields: [],
      instructionFields: [],
    }
    t.expect(programs).toEqual([
      {
        name: "TokenMetadata",
        programId: metaplexProgramId,
        instructions: [
          {
            name: "CreateMetadataAccountV3",
            discriminator: "0x21",
            registrations: [registration(0), registration(2)],
          },
          {
            name: "UpdateMetadataAccountV2",
            discriminator: "0x0f",
            registrations: [registration(1)],
          },
        ],
      },
    ])
  })

  it("stringifies schema pieces and field selections onto the inputs", t => {
    let eventConfig = makeEventConfig(
      ~selectedBlockFields=[Height, ParentHash],
      ~selectedTransactionFields=[Signature, TransactionIndex],
    )
    let eventConfig = {
      ...eventConfig,
      accounts: [Required("metadata"), Required("mint")],
      args: %raw(`[{"name": "amount", "type": "u64"}]`),
      fieldSelection: Internal.makeFieldSelection(
        ~blockFields=eventConfig.fieldSelection.blockFields,
        ~transactionFields=eventConfig.fieldSelection.transactionFields,
        ~instructionFields=Utils.Set.fromArray(["args", "accounts"]),
        ~blockMaskFn=Svm.eventBlockFieldMask,
        ~transactionMaskFn=Svm.eventTransactionFieldMask,
      ),
    }
    let where = Some(
      {"isInner": false, "accounts": {"mint": [metaplexProgramId]}}->(Utils.magic: 'a => JSON.t),
    )
    let program =
      ChainRegistrations.Svm.fromOnEventRegistrations([
        makeReg(~eventConfig, ~where),
      ])->Array.getUnsafe(0)
    let instruction = program.instructions->Array.getUnsafe(0)
    let input = instruction.registrations->Array.getUnsafe(0)
    t.expect({
      "accountFilters": input.accountFilters,
      "isInner": input.isInner,
      "transactionFields": input.transactionFields->Array.toSorted(String.compare),
      "blockFields": input.blockFields->Array.toSorted(String.compare),
      "instructionFields": input.instructionFields->Array.toSorted(String.compare),
      "argsJson": instruction.argsJson,
      "definedTypesJson": program.definedTypesJson,
    }).toEqual({
      "accountFilters": [[{ChainRegistrations.Svm.position: 1, values: [metaplexProgramId]}]],
      "isInner": Some(false),
      "transactionFields": ["signature", "transactionIndex"],
      "blockFields": ["height", "parentHash"],
      "instructionFields": ["accounts", "args"],
      "argsJson": Some(`[{"name":"amount","type":"u64"}]`),
      "definedTypesJson": None,
    })
  })
})

describe("SvmHyperSyncSource reorgable range (live)", () => {
  // Where slots can still be reorged the source reads every slot of the range,
  // which is also what lets a skipped slot fall back to the last real one's
  // time. Past the instruction, the range holds none of its own.
  Async.itWithOptions(
    "reads every slot of a range reaching reorgable slots",
    {retry: 3},
    async t => {
      let reg = makeReg()
      let source = makeSource(~onEventRegistrations=[reg])
      let slots = [slot + 1, slot + 2, slot + 3]
      let missingHashes = async reorgableFrom =>
        (
          await source->fetch(~reg, ~fromBlock=slot + 1, ~toBlock=slot + 3, ~reorgableFrom)
        ).page->BufferPage.missingHashes(slots)

      t.expect((await missingHashes(None), await missingHashes(Some(slot + 1)))).toEqual((
        slots,
        [],
      ))
    },
  )
})

describe("SvmHyperSyncSource height subscription", () => {
  Async.it("Streams heights over HyperSync SSE the same way the EVM source does", async t => {
    let (server, url) = await Promise.make(
      (resolve, _reject) => {
        let server = MockRpcServer.createServer(
          (_req, res) => {
            res->MockRpcServer.writeHead(
              200,
              dict{"Content-Type": "text/event-stream", "Cache-Control": "no-cache"},
            )
            res->MockRpcServer.write("event: height\ndata: 445073332\n\n")
            res->MockRpcServer.write("event: ping\ndata: \n\n")
            res->MockRpcServer.write("event: height\ndata: 445073335\n\n")
          },
        )
        server->MockRpcServer.listenOnHost(
          0,
          "127.0.0.1",
          () =>
            resolve((
              server,
              `http://127.0.0.1:${(server->MockRpcServer.address).port->Int.toString}`,
            )),
        )
      },
    )

    let source = makeSource(~url, ~apiToken=Some(MockHyperSyncServer.apiToken))
    let statuses = []
    let heights = []
    let unsubscribe = (source.createHeightSubscription->Option.getOrThrow)(
      ~clock=Clock.real,
      ~onHeight=height => heights->Array.push(height)->ignore,
      ~onStatus=status =>
        statuses
        ->Array.push(
          switch status {
          | Live => "live"
          | Down({reason}) => `down:${reason->Source.downReasonLabel}`
          },
        )
        ->ignore,
    )

    await Scenario.waitUntil(() => heights->Array.length === 2, ~message="the SVM height stream")
    unsubscribe()
    server->MockRpcServer.closeAllConnections
    await Promise.make((resolve, _reject) => server->MockRpcServer.close(() => resolve()))

    t.expect((statuses, heights)).toStrictEqual((["live"], [445073332, 445073335]))
  })
})

describe("SvmHyperSyncSource api token", () => {
  it("Throws the same actionable error as the EVM source when the token is missing", t => {
    t->toThrowErrorEqual(
      () => makeSource(~apiToken=None)->ignore,
      `An Envio API token is required for using HyperSync as a data-source.
Set the ENVIO_API_TOKEN environment variable in your .env file.
Learn more or get a free Envio API token at: https://envio.dev/app/api-tokens`,
    )
  })
})
