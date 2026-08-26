open Vitest

// Regression coverage for SvmHyperSyncSource.getItemsOrThrow response
// parsing, driven through a mocked napi client (no network). Query building,
// routing, and the isCommitted filter live in Rust now (covered by the
// svm_hypersync_source unit tests); this test asserts:
//   1. The per-query input passed to the client: registration indexes,
//      addresses, and the inclusive slot range.
//   2. Item building: registrations resolved by index, `block` omitted on the
//      payload (materialised from the block store at batch prep), synthesized
//      logIndex, and Rust-decoded params parsed from JSON strings.

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
    id: "0x21",
    name: "CreateMetadataAccountV3",
    contractName: "TokenMetadata",
    paramsRawEventSchema: %raw(`null`),
    simulateParamsSchema: %raw(`null`),
    programId: metaplexProgramId->SvmTypes.Pubkey.fromStringUnsafe,
    discriminator: Some("0x21"),
    discriminatorByteLen: 1,
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
    accountFilters: [],
    isInner: None,
    accounts: [],
    args: JSON.Null,
    definedTypes: JSON.Null,
  }
}

let makeReg = (~eventConfig=makeEventConfig(), ~index=0) => {
  let reg = EventConfigBuilder.buildSvmOnEventRegistration(
    ~eventConfig,
    ~isWildcard=false,
    ~handler=None,
    ~contractRegister=None,
  )
  {...reg, Internal.index: index}
}

let mockResponse: SvmHyperSyncClient.EventItems.response = {
  nextSlot: slot + 1,
  blocks: [
    {
      slot,
      blockhash: blockHash,
      blockTime: Null.make(blockTime),
    },
  ],
  items: [
    {
      onEventRegistrationIndex: 0,
      slot,
      transactionIndex: 965,
      path: [1],
      programId: metaplexProgramId,
      accounts: [],
      data: "0x21",
      isInner: false,
      argsJson: `{"amount":"1"}`,
      logs: Null.null,
    },
  ],
}

let capturedQueries: array<SvmHyperSyncClient.EventItems.query> = []
let capturedRegistrationInputs: array<array<SvmHyperSyncClient.Registration.input>> = []

// The chain's address index; created outside the mock-addon window below so it
// loads the real native addon.
let addressStore = AddressStore.make(
  ~ecosystem=Ecosystem.Svm,
  ~shouldChecksum=false,
  ~contracts=[{name: "TokenMetadata", startBlock: None, dependsOnAddresses: true}],
)

let makeMockClient = (~response=mockResponse): SvmHyperSyncClient.t => {
  getHeight: () => Promise.resolve(slot + 1000),
  getBlockHashes: (~blockNumbers as _) =>
    JsError.throwWithMessage("getBlockHashes should not be used in these tests"),
  get: (~query as _) =>
    JsError.throwWithMessage("get should only be used for block-data queries in tests"),
  getEventItems: (~query, ~addressSet as _) => {
    capturedQueries->Array.push(query)
    // The real Rust client builds the stores from raw transactions/blocks; the
    // mock returns empty pages (materialisation is covered by the Rust unit
    // tests).
    Promise.resolve((
      response,
      TransactionStore.make(~ecosystem=Ecosystem.Svm, ~shouldChecksum=false),
      BlockStore.make(~ecosystem=Ecosystem.Svm, ~shouldChecksum=false),
    ))
  },
}

let mockClient = makeMockClient()

// The source captures its client at construction, so the mock addon only
// needs to be in place for the `make` call; restore the previous addon right
// after to avoid leaking the mock into other tests.
let makeSource = (~onEventRegistrations=[makeReg()], ~client=mockClient) => {
  let prevAddon = Core.addonRef.contents
  Core.addonRef :=
    Some(
      {
        "SvmHyperSyncClient": {
          "fromConfig": (
            _: SvmHyperSyncClient.cfg,
            _: string,
            registrations: array<SvmHyperSyncClient.Registration.input>,
            _: AddressStore.t,
          ) => {
            capturedRegistrationInputs->Array.push(registrations)
            client
          },
        },
      }->(Utils.magic: {..} => Core.addon),
    )
  let source = try SvmHyperSyncSource.make({
    chainId,
    endpointUrl: "https://solana.hypersync.xyz",
    apiToken: None,
    onEventRegistrations,
    clientTimeoutMillis: 10_000,
    addressStore,
  }) catch {
  | exn =>
    Core.addonRef := prevAddon
    throw(exn)
  }
  Core.addonRef := prevAddon
  source
}

// The chain's address index, with the Metaplex program registered for the
// TokenMetadata program name.
let programSet = {
  let _ = addressStore->AddressStore.seedBatch([
    {
      address: metaplexProgramId->Address.unsafeFromString,
      contractName: "TokenMetadata",
      registrationBlock: -1,
    },
  ])
  addressStore->AddressStore.makeSet(~contractName="TokenMetadata")
}

describe("SvmHyperSyncSource.getItemsOrThrow (mocked client)", () => {
  Async.it(
    "passes the selection to the client and builds items by registration index",
    async t => {
      let reg = makeReg()
      let source = makeSource(~onEventRegistrations=[reg])

      let response = await source.getItemsOrThrow(
        ~fromBlock=slot - 10,
        ~toBlock=Some(slot + 10),
        ~addressSet=programSet,
        ~knownHeight=slot + 1000,
        ~partitionId="0",
        ~itemsTarget=Some(5000),
        ~selection={
          onEventRegistrations: [reg],
          dependsOnAddresses: true,
        },
        ~retry=0,
        ~logger=Logging.createChild(~params={"test": "SvmHyperSyncSource"}),
      )

      let item = switch response.parsedQueueItems {
      | [
          Internal.Event({
            blockNumber,
            logIndex,
            orderPath,
            transactionIndex,
            payload,
            onEventRegistration,
          }),
        ] =>
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

      t.expect({
        "item": item,
        "query": capturedQueries->Array.getUnsafe(0),
      }).toEqual({
        "item": Some({
          "blockNumber": slot,
          "logIndex": 965,
          "orderPath": [1],
          "transactionIndex": 965,
          "block": None,
          "args": None,
          "accounts": None,
          "usesSourceRegistration": true,
        }),
        // The slot range stays inclusive on the boundary; Rust converts to the
        // wire's exclusive `toSlot`.
        "query": (
          {
            fromSlot: slot - 10,
            toSlot: Some(slot + 10),
            maxNumInstructions: 5000,
            registrationIndexes: [0],
            clientFilteredContracts: None,
          }: SvmHyperSyncClient.EventItems.query
        ),
      })
    },
  )

  // The whole registration set crosses the boundary once at construction —
  // selections, field unions, decoders, and routing derive from it in Rust.
  it("builds registration inputs from the event configs", t => {
    let _ = makeSource(~onEventRegistrations=[makeReg()])
    let inputs =
      capturedRegistrationInputs->Array.getUnsafe(capturedRegistrationInputs->Array.length - 1)
    t.expect(inputs).toEqual([
      {
        index: 0,
        instructionName: "CreateMetadataAccountV3",
        contractName: "TokenMetadata",
        programId: metaplexProgramId,
        isWildcard: false,
        startBlock: None,
        discriminator: "0x21",
        accountFilters: [],
        transactionFields: [],
        blockFields: [],
        accountActivityFields: [],
        logFields: [],
        instructionFields: [],
        accounts: [],
      },
    ])
  })

  it("stringifies schema pieces and field selections onto registration inputs", t => {
    let eventConfig = makeEventConfig(
      ~selectedBlockFields=[Height, ParentHash],
      ~selectedTransactionFields=[Signature, TransactionIndex],
    )
    let eventConfig = {
      ...eventConfig,
      accounts: ["metadata", "mint"],
      args: %raw(`[{"name": "amount", "type": "u64"}]`),
      isInner: Some(false),
      accountFilters: [
        [
          {
            Internal.position: 1,
            values: [metaplexProgramId->SvmTypes.Pubkey.fromStringUnsafe],
          },
        ],
      ],
      fieldSelection: Internal.makeFieldSelection(
        ~blockFields=eventConfig.fieldSelection.blockFields,
        ~transactionFields=eventConfig.fieldSelection.transactionFields,
        ~instructionFields=Utils.Set.fromArray(["args", "accounts"]),
        ~blockMaskFn=Svm.eventBlockFieldMask,
        ~transactionMaskFn=Svm.eventTransactionFieldMask,
      ),
    }
    let _ = makeSource(~onEventRegistrations=[makeReg(~eventConfig)])
    let inputs =
      capturedRegistrationInputs->Array.getUnsafe(capturedRegistrationInputs->Array.length - 1)
    let input = inputs->Array.getUnsafe(0)
    t.expect({
      "accountFilters": input.accountFilters,
      "isInner": input.isInner,
      "transactionFields": input.transactionFields->Array.toSorted(String.compare),
      "blockFields": input.blockFields->Array.toSorted(String.compare),
      "instructionFields": input.instructionFields->Array.toSorted(String.compare),
      "accounts": input.accounts,
      "argsJson": input.argsJson,
      "definedTypesJson": input.definedTypesJson,
    }).toEqual({
      "accountFilters": [[{SvmHyperSyncClient.Registration.position: 1, values: [metaplexProgramId]}]],
      "isInner": Some(false),
      "transactionFields": ["signature", "transactionIndex"],
      "blockFields": ["height", "parentHash"],
      "instructionFields": ["accounts", "args"],
      "accounts": ["metadata", "mint"],
      "argsJson": Some(`[{"name":"amount","type":"u64"}]`),
      "definedTypesJson": None,
    })
  })
})
