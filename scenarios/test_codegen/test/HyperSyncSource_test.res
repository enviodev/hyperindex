open Vitest

let mockAddress0 = Envio.TestHelpers.Addresses.mockAddresses[0]->Option.getOrThrow

// Valid 32-byte sighashes — the Rust client hex-decodes them at construction.
let hexId = suffix => "0x" ++ "00"->String.repeat(31) ++ suffix
let sighash1 = hexId("01")
let sighash2 = hexId("02")

// `buildLogSelections` exposes the selections a query would fetch for a given
// registration selection and address index.
let makeClient = (registrations: array<Internal.evmOnEventRegistration>) => {
  let registrations = registrations->Array.mapWithIndex((reg, i) => {...reg, index: i})
  EvmRpcClient.make(
    ~url="http://localhost:1",
    ~checksumAddresses=false,
    ~syncConfig=EvmChain.getSyncConfig({}),
    ~eventRegistrations=HyperSyncClient.Registration.fromOnEventRegistrations(registrations),
  )
}

// Rust encodes ContractAddresses-marker topics as lowercase padded hex.
let addressTopic = (address: Address.t) =>
  "0x000000000000000000000000" ++
  address->Address.toString->String.toLowerCase->String.slice(~start=2)

describe("EvmClient - buildLogSelections", () => {
  it("Scopes an address-bound event to its contract's addresses", t => {
    let client = makeClient([MockIndexer.evmOnEventRegistration(~id=sighash1)])

    t.expect(
      client.buildLogSelections([0], Dict.make()),
      ~message=`Shouldn't have a log selection without addresses.
        This is actually a wrong a behaviour and should throw in this case.
        If this happens it means we incorrectly created partitions for fetch state`,
    ).toEqual([])

    t.expect(
      client.buildLogSelections([0], Dict.fromArray([("ERC20", [mockAddress0])])),
      ~message=`Should have a log selection when an address is provided`,
    ).toEqual([
      {
        addresses: [mockAddress0],
        topics: [[sighash1], [], [], []],
      },
    ])

    t.expect(
      client.buildLogSelections([0], Dict.fromArray([("Bar", [mockAddress0])])),
      ~message=`Shouldn't have a log selection when contract name doesn't much the one in selection`,
    ).toEqual([])
  })

  it("Topic selection with two wildcard events", t => {
    let client = makeClient([
      MockIndexer.evmOnEventRegistration(~id=sighash1, ~isWildcard=true),
      MockIndexer.evmOnEventRegistration(~id=sighash2, ~isWildcard=true, ~contractName="Other"),
    ])

    t.expect(
      client.buildLogSelections([0, 1], Dict.make()),
      ~message=`Even though wildcard events belong to different contracts, they should be joined in to a single log selection`,
    ).toEqual([
      {
        addresses: [],
        topics: [[sighash1, sighash2], [], [], []],
      },
    ])
  })

  it(
    "Normal topic selection which depends on addresses & wildcard topic selection which depends on addresses",
    t => {
      let client = makeClient([
        MockIndexer.evmOnEventRegistration(~id=sighash1),
        MockIndexer.evmOnEventRegistration(
          ~id=sighash2,
          ~isWildcard=true,
          ~dependsOnAddresses=true,
        ),
      ])

      t.expect(
        client.buildLogSelections([0, 1], Dict.fromArray([("ERC20", [mockAddress0])])),
      ).toEqual([
        {
          addresses: [mockAddress0],
          topics: [[sighash1], [], [], []],
        },
        {
          addresses: [],
          topics: [[sighash2], [addressTopic(mockAddress0)], [], []],
        },
      ])
    },
  )

  it("Fans out one selection per wildcard event that has filters", t => {
    let client = makeClient([
      MockIndexer.evmOnEventRegistration(
        ~id=sighash1,
        ~isWildcard=true,
        ~eventFilters=[
          {
            topic0: [sighash1->EvmTypes.Hex.fromStringUnsafe],
            topic1: Values(["a"->EvmTypes.Hex.fromStringUnsafe]),
            topic2: Values([]),
            topic3: Values([]),
          },
        ],
      ),
      MockIndexer.evmOnEventRegistration(
        ~id=sighash2,
        ~isWildcard=true,
        ~contractName="Other",
        ~eventFilters=[
          {
            topic0: [sighash2->EvmTypes.Hex.fromStringUnsafe],
            topic1: Values(["b"->EvmTypes.Hex.fromStringUnsafe]),
            topic2: Values([]),
            topic3: Values([]),
          },
        ],
      ),
    ])

    t.expect(client.buildLogSelections([0, 1], Dict.make())).toEqual([
      {
        addresses: [],
        topics: [[sighash1], ["a"], [], []],
      },
      {
        addresses: [],
        topics: [[sighash2], ["b"], [], []],
      },
    ])
  })

  it("Fans out one selection per group of a single wildcard event's OR filter", t => {
    let client = makeClient([
      MockIndexer.evmOnEventRegistration(
        ~id=sighash1,
        ~isWildcard=true,
        ~eventFilters=[
          {
            topic0: [sighash1->EvmTypes.Hex.fromStringUnsafe],
            topic1: Values(["a"->EvmTypes.Hex.fromStringUnsafe]),
            topic2: Values([]),
            topic3: Values([]),
          },
          {
            topic0: [sighash1->EvmTypes.Hex.fromStringUnsafe],
            topic1: Values([]),
            topic2: Values(["b"->EvmTypes.Hex.fromStringUnsafe]),
            topic3: Values([]),
          },
        ],
      ),
    ])

    t.expect(client.buildLogSelections([0], Dict.make())).toEqual([
      {
        addresses: [],
        topics: [[sighash1], ["a"], [], []],
      },
      {
        addresses: [],
        topics: [[sighash1], [], ["b"], []],
      },
    ])
  })

  it("Only includes the queried selection's registrations", t => {
    let client = makeClient([
      MockIndexer.evmOnEventRegistration(~id=sighash1, ~isWildcard=true),
      MockIndexer.evmOnEventRegistration(
        ~id=sighash2,
        ~isWildcard=true,
        ~contractName="Other",
      ),
    ])

    t.expect(client.buildLogSelections([1], Dict.make())).toEqual([
      {
        addresses: [],
        topics: [[sighash2], [], [], []],
      },
    ])
  })
})
