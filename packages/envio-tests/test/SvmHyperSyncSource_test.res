open Vitest

// Regression coverage for how the SVM source turns a page into items, and for
// what it hands the client at construction, with a mocked napi client (no
// network). The query each page asks for, routing and the isCommitted filter
// live in Rust (covered by the svm_hypersync_source unit tests); this test
// asserts item building: registrations resolved by index, `block` omitted on
// the payload (materialised from the block store at batch prep), synthesized
// logIndex, and Rust-decoded params passed through as values.

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

let mockResponse: SvmHyperSyncClient.Items.response = {
  nextSlot: slot + 1,
  blockItems: [],
  eventItems: [
    {
      onEventRegistrationIndex: 0,
      slot,
      transactionIndex: 965,
      path: [1],
      programId: metaplexProgramId,
      accounts: [],
      data: Uint8Array.fromArray([0x21]),
      isInner: false,
      args: Nullable.undefined,
      logs: Nullable.undefined,
    },
  ],
}

let capturedPrograms: array<array<SvmHyperSyncClient.Registration.program>> = []

// The chain's address index; created outside the mock-addon window below so it
// loads the real native addon.
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

let makeMockClient = (~response=mockResponse): SvmHyperSyncClient.t => {
  getHeight: () => Promise.resolve(slot + 1000),
  getBlockHashes: (~blockNumbers as _) =>
    JsError.throwWithMessage("getBlockHashes should not be used in these tests"),
  getItems: (~query as _, ~addressSet as _) =>
    Promise.resolve((
      response,
      TransactionStore.make(~ecosystem=Ecosystem.Svm),
      BlockStore.make(~ecosystem=Ecosystem.Svm),
    )),
  source: (_, _, _) => %raw(`{}`),
}

let mockClient = makeMockClient()

// The source captures its client at construction, so the mock addon only
// needs to be in place for the `make` call; restore the previous addon right
// after to avoid leaking the mock into other tests.
let makeSource = (
  ~onEventRegistrations=[makeReg()],
  ~client=mockClient,
  ~endpointUrl="https://solana.hypersync.xyz",
  ~apiToken=Some("test-token"),
) => {
  let prevAddon = Core.addonRef.contents
  Core.addonRef :=
    Some(
      {
        "SvmHyperSyncClient": {
          "fromConfig": (
            _: SvmHyperSyncClient.cfg,
            _: string,
            programs: array<SvmHyperSyncClient.Registration.program>,
            _: AddressStore.t,
          ) => {
            capturedPrograms->Array.push(programs)
            client
          },
        },
      }->(Utils.magic: {..} => Core.addon),
    )
  let source = try SvmHyperSyncSource.make({
    chainId,
    endpointUrl,
    apiToken,
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

// The Metaplex program, registered under the TokenMetadata program name.
let programSet = addressStore->AddressStore.makeSet(~contractName="TokenMetadata")

// The page a source built in Rust hands over, decoded the way the source
// manager decodes it.
let decode = (source: Source.t, page: SvmHyperSyncClient.Items.page) =>
  switch source.implementation {
  | Rust({decodeItemsPage}) =>
    page
    ->(Utils.magic: SvmHyperSyncClient.Items.page => NativeSource.page)
    ->decodeItemsPage(~knownHeight=slot + 1000)
  | ReScript(_) => JsError.throwWithMessage("The SVM source is built in Rust.")
  }

describe("SvmHyperSyncSource (mocked client)", () => {
  it("builds items by registration index", t => {
    let reg = makeReg()
    let source = makeSource(~onEventRegistrations=[reg])

    let response = source->decode({
      toBlock: slot,
      eventItems: mockResponse.eventItems,
      blockItems: [],
      blocks: BlockStore.make(~ecosystem=Ecosystem.Svm),
      transactions: TransactionStore.make(~ecosystem=Ecosystem.Svm),
      fetchSeconds: 0.,
    })

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

    t.expect((item, response.latestFetchedBlockNumber)).toEqual((
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
      slot,
    ))
  })

  // The whole registration set crosses the boundary once at construction,
  // grouped under the config instruction each registration was built from:
  // selections, field unions, decoders, and routing derive from it in Rust.
  it("groups registrations under their program and instruction", t => {
    let swap = makeEventConfig()
    let other = {...makeEventConfig(), name: "UpdateMetadataAccountV2", discriminator: Some("0x0f")}
    let _ = makeSource(
      ~onEventRegistrations=[
        makeReg(~eventConfig=swap, ~index=0),
        makeReg(~eventConfig=other, ~index=1),
        makeReg(~eventConfig=swap, ~index=2),
      ],
    )
    let programs = capturedPrograms->Array.getUnsafe(capturedPrograms->Array.length - 1)
    let registration = index => {
      SvmHyperSyncClient.Registration.index,
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
    let _ = makeSource(~onEventRegistrations=[makeReg(~eventConfig, ~where)])
    let program =
      capturedPrograms
      ->Array.getUnsafe(capturedPrograms->Array.length - 1)
      ->Array.getUnsafe(0)
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
      "accountFilters": [
        [{SvmHyperSyncClient.Registration.position: 1, values: [metaplexProgramId]}],
      ],
      "isInner": Some(false),
      "transactionFields": ["signature", "transactionIndex"],
      "blockFields": ["height", "parentHash"],
      "instructionFields": ["accounts", "args"],
      "argsJson": Some(`[{"name":"amount","type":"u64"}]`),
      "definedTypesJson": None,
    })
  })
})

describe("SvmHyperSyncSource height subscription", () => {
  it("Pushes slots over HyperSync's stream the same way the EVM source does", t => {
    let source = SvmHyperSyncSource.make({
      chainId,
      endpointUrl: "http://127.0.0.1:1",
      apiToken: Some("test-token"),
      onEventRegistrations: [makeReg()],
      clientTimeoutMillis: 10_000,
      addressStore,
    })

    t.expect(source->Source.canStream).toBe(true)
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
