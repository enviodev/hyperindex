open Vitest

// The simulate source has no backend to filter for it, so it has to reproduce
// the gates a real source applies natively while routing a response: the
// partition's own address set decides ownership, the store decides whether the
// address had started at the item's block, and a client-filtered contract —
// queried address-free, so absent from every set — falls back to the store
// alone.

let addr = i => Envio.TestHelpers.Addresses.mockAddresses[i]->Option.getOrThrow

let chainId = 1->ChainId.fromInt

let registration = (
  ~index,
  ~contractName,
  ~isWildcard=false,
  ~startBlock=?,
  ~addressFilterParamGroups=?,
) => {
  let base = (EventRegistration.evmOnEventRegistration(
    ~id=index->Int.toString,
    ~contractName,
    ~isWildcard,
    ~startBlock?,
  ) :> Internal.onEventRegistration)
  {
    ...base,
    index,
    addressFilterParamGroups: addressFilterParamGroups->Option.getOr([]),
  }
}

let contract = (~address, ~contractName, ~registrationBlock=-1): Internal.indexingAddress => {
  address,
  contractName,
  registrationBlock,
}

let item = (~registration: Internal.onEventRegistration, ~blockNumber, ~srcAddress, ~params=?) =>
  Internal.Event({
    chainId,
    blockNumber,
    logIndex: 0,
    transactionIndex: 0,
    onEventRegistration: registration,
    payload: {"srcAddress": srcAddress, "params": params->Option.getOr(Dict.make())}->(
      Utils.magic: {"srcAddress": Address.t, "params": dict<Address.t>} => Internal.eventPayload
    ),
  })

let getItems = async (
  ~items,
  ~store,
  ~addressSet,
  ~selection: FetchState.selection,
  ~fromBlock=0,
  ~toBlock=1000,
) => {
  let source = SimulateSource.make(~items, ~endBlock=1000, ~chainId, ~addressStore=store)
  let response = await source.getItemsOrThrow(
    ~fromBlock,
    ~toBlock=Some(toBlock),
    ~addressSet,
    ~knownHeight=1000,
    ~partitionId="0",
    ~selection,
    ~itemsTarget=None,
    ~retry=0,
    ~logger=Logging.getLogger(),
  )
  response.parsedQueueItems->Array.map(item => {
    let eventItem = item->Internal.castUnsafeEventItem
    (
      eventItem.onEventRegistration.index,
      eventItem.blockNumber,
      eventItem.payload->Internal.getPayloadSrcAddress,
    )
  })
}

describe("SimulateSource routing", () => {
  Async.it("keeps each partition to the addresses it holds", async t => {
    let regA = registration(~index=0, ~contractName="A")
    let store = TestAddresses.makeStore(
      ~onEventRegistrations=[regA],
      ~addresses=[
        contract(~address=addr(0), ~contractName="A"),
        contract(~address=addr(1), ~contractName="A"),
      ],
    )
    let selection: FetchState.selection = {
      dependsOnAddresses: true,
      onEventRegistrations: [regA],
    }
    let items = [
      item(~registration=regA, ~blockNumber=10, ~srcAddress=addr(0)),
      item(~registration=regA, ~blockNumber=10, ~srcAddress=addr(1)),
    ]

    let first = await getItems(
      ~items,
      ~store,
      ~addressSet=TestAddresses.setOf(~store, [addr(0)]),
      ~selection,
    )
    let second = await getItems(
      ~items,
      ~store,
      ~addressSet=TestAddresses.setOf(~store, [addr(1)]),
      ~selection,
    )

    t.expect({"first": first, "second": second}).toEqual({
      "first": [(0, 10, addr(0))],
      "second": [(0, 10, addr(1))],
    })
  })

  Async.it("drops an address the partition holds but that hasn't started yet", async t => {
    let regA = registration(~index=0, ~contractName="A")
    let store = TestAddresses.makeStore(
      ~onEventRegistrations=[regA],
      ~addresses=[contract(~address=addr(0), ~contractName="A", ~registrationBlock=50)],
    )
    let selection: FetchState.selection = {
      dependsOnAddresses: true,
      onEventRegistrations: [regA],
    }

    let routed = await getItems(
      ~store,
      ~items=[
        item(~registration=regA, ~blockNumber=49, ~srcAddress=addr(0)),
        item(~registration=regA, ~blockNumber=50, ~srcAddress=addr(0)),
      ],
      ~addressSet=TestAddresses.setOf(~store, [addr(0)]),
      ~selection,
    )

    t.expect(routed).toEqual([(0, 50, addr(0))])
  })

  Async.it("routes a client-filtered contract on the store alone", async t => {
    let regA = registration(~index=0, ~contractName="A")
    let store = TestAddresses.makeStore(
      ~onEventRegistrations=[regA],
      ~addresses=[contract(~address=addr(0), ~contractName="A", ~registrationBlock=50)],
    )
    // The query carries none of A's addresses, which is what makes the
    // partition's set unable to answer ownership for it.
    let addressSet = store->AddressStore.emptySet
    let items = [
      item(~registration=regA, ~blockNumber=49, ~srcAddress=addr(0)),
      item(~registration=regA, ~blockNumber=50, ~srcAddress=addr(0)),
      item(~registration=regA, ~blockNumber=50, ~srcAddress=addr(9)),
    ]

    let clientFiltered = await getItems(
      ~items,
      ~store,
      ~addressSet,
      ~selection={
        dependsOnAddresses: true,
        onEventRegistrations: [regA],
        clientFilteredContracts: ["A"],
      },
    )
    // Without the client-filter marker the same query is a normal partition
    // that simply holds no addresses, so it routes nothing.
    let normal = await getItems(
      ~items,
      ~store,
      ~addressSet,
      ~selection={dependsOnAddresses: true, onEventRegistrations: [regA]},
    )

    t.expect({"clientFiltered": clientFiltered, "normal": normal}).toEqual({
      "clientFiltered": [(0, 50, addr(0))],
      "normal": [],
    })
  })

  Async.it("applies the same rule to address-valued params", async t => {
    let regWildcard = registration(
      ~index=0,
      ~contractName="A",
      ~isWildcard=true,
      ~addressFilterParamGroups=[["to"]],
    )
    let store = TestAddresses.makeStore(
      ~onEventRegistrations=[regWildcard],
      ~addresses=[
        contract(~address=addr(0), ~contractName="A"),
        contract(~address=addr(1), ~contractName="A"),
      ],
    )
    let selection: FetchState.selection = {
      dependsOnAddresses: true,
      onEventRegistrations: [regWildcard],
    }
    let items = [
      item(
        ~registration=regWildcard,
        ~blockNumber=10,
        ~srcAddress=addr(9),
        ~params=Dict.fromArray([("to", addr(0))]),
      ),
      item(
        ~registration=regWildcard,
        ~blockNumber=10,
        ~srcAddress=addr(9),
        ~params=Dict.fromArray([("to", addr(1))]),
      ),
    ]

    let partitionScoped = await getItems(
      ~items,
      ~store,
      ~addressSet=TestAddresses.setOf(~store, [addr(0)]),
      ~selection,
    )
    let clientFiltered = await getItems(
      ~items,
      ~store,
      ~addressSet=TestAddresses.setOf(~store, [addr(0)]),
      ~selection={...selection, clientFilteredContracts: ["A"]},
    )

    t.expect({"partitionScoped": partitionScoped, "clientFiltered": clientFiltered}).toEqual({
      "partitionScoped": [(0, 10, addr(9))],
      // Chain-wide, so addr(1) passes too even though the set lacks it.
      "clientFiltered": [(0, 10, addr(9)), (0, 10, addr(9))],
    })
  })

  Async.it("holds back a registration by its own start block", async t => {
    // The store's start block is contract-wide, so the unrestricted sibling
    // keeps the address gate open from block 0 — only the per-registration
    // gate the native routers apply can separate the two.
    let regOpen = registration(~index=0, ~contractName="A")
    let regRestricted = registration(~index=1, ~contractName="A", ~startBlock=100)
    let store = TestAddresses.makeStore(
      ~onEventRegistrations=[regOpen, regRestricted],
      ~addresses=[contract(~address=addr(0), ~contractName="A")],
    )

    let routed = await getItems(
      ~store,
      ~items=[
        item(~registration=regOpen, ~blockNumber=99, ~srcAddress=addr(0)),
        item(~registration=regRestricted, ~blockNumber=99, ~srcAddress=addr(0)),
        item(~registration=regOpen, ~blockNumber=100, ~srcAddress=addr(0)),
        item(~registration=regRestricted, ~blockNumber=100, ~srcAddress=addr(0)),
      ],
      ~addressSet=TestAddresses.setOf(~store, [addr(0)]),
      ~selection={dependsOnAddresses: true, onEventRegistrations: [regOpen, regRestricted]},
    )

    t.expect(routed).toEqual([(0, 99, addr(0)), (0, 100, addr(0)), (1, 100, addr(0))])
  })

  Async.it("keeps registrations of the same event in their own partitions", async t => {
    // Same event id, two registrations — matching a selection on the event id
    // would hand each partition both registrations' items.
    let regFirst = registration(~index=0, ~contractName="A")
    let regSecond = {...regFirst, index: 1}
    let store = TestAddresses.makeStore(
      ~onEventRegistrations=[regFirst, regSecond],
      ~addresses=[contract(~address=addr(0), ~contractName="A")],
    )
    let addressSet = TestAddresses.setOf(~store, [addr(0)])
    let items = [
      item(~registration=regFirst, ~blockNumber=10, ~srcAddress=addr(0)),
      item(~registration=regSecond, ~blockNumber=10, ~srcAddress=addr(0)),
    ]

    let first = await getItems(
      ~items,
      ~store,
      ~addressSet,
      ~selection={dependsOnAddresses: true, onEventRegistrations: [regFirst]},
    )
    let both = await getItems(
      ~items,
      ~store,
      ~addressSet,
      ~selection={dependsOnAddresses: true, onEventRegistrations: [regFirst, regSecond]},
    )

    t.expect({"first": first, "both": both}).toEqual({
      "first": [(0, 10, addr(0))],
      "both": [(0, 10, addr(0)), (1, 10, addr(0))],
    })
  })
})
