open Vitest

let address = "0x00000000000000000000000000000000000000c1"->Address.unsafeFromString
let blocks = [30, 10, 20]

let makeStore = (~startBlock=?) =>
  AddressStore.make(
    ~ecosystem=Evm,
    ~contracts=[{name: "Child", startBlock, dependsOnAddresses: true}],
  )

let registration = (registrationBlock): AddressStore.registration => {
  address,
  contractName: "Child",
  registrationBlock,
}

let rec permutations = values =>
  switch values {
  | [] => [[]]
  | _ =>
    values->Array.flatMap(value =>
      values
      ->Array.filter(other => other !== value)
      ->permutations
      ->Array.map(rest => [value]->Array.concat(rest))
    )
  }

let verdictName = (verdict: AddressStore.verdict) =>
  switch verdict {
  | Added(_) => "added"
  | Duplicate => "duplicate"
  | Invalid => "invalid"
  }

// What the store says about the address once every registration is in.
let describeStore = store => (
  store->AddressStore.isIndexedAt(address, "Child", 9),
  store->AddressStore.isIndexedAt(address, "Child", 10),
  store->AddressStore.contractCount("Child"),
  store
  ->AddressStore.drainForWrite(1000, blocks)
  ->Array.map(drained => drained.registrationBlock),
)

let indexedFromTheLowest = (false, true, 1, [10])

// https://github.com/enviodev/hyperindex/issues/1810
describe("An address registered for one contract from several blocks", () => {
  permutations(blocks)->Array.forEach(order => {
    let name = order->Array.map(block => block->Int.toString)->Array.join(", ")

    it(
      `is indexed from the lowest when registered at ${name}, one batch each`,
      t => {
        let store = makeStore()
        let verdicts =
          order->Array.flatMap(
            block =>
              store->AddressStore.registerBatch([registration(block)])->Array.map(verdictName),
          )
        let expectedVerdicts =
          order->Array.mapWithIndex(
            (block, idx) =>
              order->Array.slice(~start=0, ~end=idx)->Array.every(earlier => earlier > block)
                ? "added"
                : "duplicate",
          )
        t.expect((verdicts, describeStore(store))).toEqual((expectedVerdicts, indexedFromTheLowest))
      },
    )

    it(
      `is indexed from the lowest when registered at ${name} in one batch`,
      t => {
        let store = makeStore()
        let _ = store->AddressStore.registerBatch(order->Array.map(registration))
        t.expect(describeStore(store)).toEqual(indexedFromTheLowest)
      },
    )
  })

  // Below the contract's start block both registrations start at 200, so only
  // their blocks tell them apart: the earlier one is what a rollback to between
  // them keeps.
  it("keeps the earlier of two registrations below the contract's start block", t => {
    let store = makeStore(~startBlock=200)
    let verdicts =
      [150, 110]->Array.flatMap(
        block => store->AddressStore.registerBatch([registration(block)])->Array.map(verdictName),
      )
    t.expect((
      verdicts,
      store->AddressStore.isIndexedAt(address, "Child", 199),
      store->AddressStore.isIndexedAt(address, "Child", 200),
      store
      ->AddressStore.drainForWrite(1000, [110, 150])
      ->Array.map(drained => drained.registrationBlock),
    )).toEqual((["added", "added"], false, true, [110]))
  })
})
