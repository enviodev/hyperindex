open Vitest

// The inline `fields` option of `onEvent`/`contractRegister`: it replaces the
// config `field_selection` for that registration, so two registrations of one
// event can read different fields.

let makeConfig = (~rawEvents=false) =>
  InternalTestIndexer.fromUserApi(~configYaml=`
name: inline-field-selection${rawEvents ? "-raw" : ""}
raw_events: ${rawEvents ? "true" : "false"}
field_selection:
  block_fields:
    - miner
  transaction_fields:
    - hash
contracts:
  - name: ERC20
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1111111111111111111111111111111111111111"
`).config

let config = makeConfig()
let configWithRawEvents = makeConfig(~rawEvents=true)

let rpcConfig = InternalTestIndexer.fromUserApi(~configYaml=`
name: inline-field-selection-rpc
contracts:
  - name: ERC20
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 0
    rpc:
      url: "https://rpc.example.test"
      for: sync
    contracts:
      - name: ERC20
        address: "0x1111111111111111111111111111111111111111"
`).config

let makeHandler = (): Internal.handler => %raw(`() => Promise.resolve()`)
let makeContractRegister = (): Internal.contractRegister => %raw(`() => Promise.resolve()`)

let setHandler = (~eventOptions=?, handler) =>
  HandlerRegister.setHandler(
    ~contractName="ERC20",
    ~eventName="Transfer",
    handler->(Utils.magic: Internal.handler => Internal.genericHandler<_>),
    ~eventOptions,
  )

let setContractRegister = (~eventOptions=?, contractRegister) =>
  HandlerRegister.setContractRegister(
    ~contractName="ERC20",
    ~eventName="Transfer",
    contractRegister->(Utils.magic: Internal.contractRegister => Internal.genericContractRegister<_>),
    ~eventOptions,
  )

let register = (~config=config, fn) => {
  HandlerRegister.resetOnEventRegistrations()
  HandlerRegister.startRegistration(~config)
  fn()
  HandlerRegister.finishRegistration(~config)
}

// Per-registration selection on chain 1, as sorted field-name arrays.
let selections = (registrations: HandlerRegister.registrationsByChainId, ~chainKey="1") => {
  let chainRegistrations: HandlerRegister.chainRegistrations =
    registrations->Utils.Dict.dangerouslyGetNonOption(chainKey)->Option.getOrThrow
  chainRegistrations.onEventRegistrations->Array.map(reg => (
    reg.selectedBlockFields->Utils.Set.toArray->Array.toSorted(String.compare),
    reg.selectedTransactionFields->Utils.Set.toArray->Array.toSorted(String.compare),
  ))
}

let withFields = (~block=?, ~transaction=?, ()): Internal.eventOptions<JSON.t> => {
  fields: {block: ?block, transaction: ?transaction},
}

describe("EVM inline field selection", () => {
  it("replaces the config selection, keeping the internally required block fields", t => {
    let registrations = register(() =>
      setHandler(~eventOptions=withFields(~block=["parentHash"], ~transaction=["to"], ()), makeHandler())
    )
    t.expect(registrations->selections).toEqual([
      (["number", "parentHash", "timestamp"], ["to"]),
    ])
  })

  it("falls back to the config selection without the option", t => {
    let registrations = register(() => setHandler(makeHandler()))
    t.expect(registrations->selections).toEqual([
      (["hash", "miner", "number", "timestamp"], ["hash"]),
    ])
  })

  it("accepts an always-included field in the list without duplicating it", t => {
    let registrations = register(() =>
      setHandler(~eventOptions=withFields(~block=["number", "timestamp"], ()), makeHandler())
    )
    t.expect(registrations->selections).toEqual([(["number", "timestamp"], [])])
  })

  it("keeps two handlers separate, each with its own selection", t => {
    let registrations = register(() => {
      setHandler(~eventOptions=withFields(~block=["parentHash"], ()), makeHandler())
      setHandler(~eventOptions=withFields(~transaction=["gasUsed"], ()), makeHandler())
    })
    t.expect(registrations->selections).toEqual([
      (["number", "parentHash", "timestamp"], []),
      (["number", "timestamp"], ["gasUsed"]),
    ])
  })

  it("unions the selection when a contractRegister merges into a handler", t => {
    let registrations = register(() => {
      setHandler(~eventOptions=withFields(~block=["parentHash"], ()), makeHandler())
      setContractRegister(~eventOptions=withFields(~transaction=["gasUsed"], ()), makeContractRegister())
    })
    t.expect(registrations->selections).toEqual([
      (["number", "parentHash", "timestamp"], ["gasUsed"]),
    ])
  })

  it("unions the selection when a handler merges into an earlier contractRegister", t => {
    let registrations = register(() => {
      setContractRegister(~eventOptions=withFields(~transaction=["gasUsed"], ()), makeContractRegister())
      setHandler(~eventOptions=withFields(~block=["parentHash"], ()), makeHandler())
    })
    t.expect(registrations->selections).toEqual([
      (["number", "parentHash", "timestamp"], ["gasUsed"]),
    ])
  })

  // `toRawEvent` reads block.hash/block.timestamp off the payload, so they stay
  // materialised even though the handler's type doesn't expose them.
  it("keeps block hash and timestamp selected when the project stores raw events", t => {
    let registrations = register(~config=configWithRawEvents, () =>
      setHandler(~eventOptions=withFields(~block=["parentHash"], ()), makeHandler())
    )
    t.expect(registrations->selections).toEqual([
      (["hash", "number", "parentHash", "timestamp"], []),
    ])
  })

  it("passes each registration's own selection to the source query input", t => {
    let registrations = register(() => {
      setHandler(~eventOptions=withFields(~block=["parentHash"], ()), makeHandler())
      setHandler(~eventOptions=withFields(~transaction=["gasUsed"], ()), makeHandler())
    })
    let chainRegistrations: HandlerRegister.chainRegistrations =
      registrations->Utils.Dict.dangerouslyGetNonOption("1")->Option.getOrThrow
    let inputs =
      chainRegistrations.onEventRegistrations
      ->(
        Utils.magic: array<Internal.onEventRegistration> => array<Internal.evmOnEventRegistration>
      )
      ->HyperSyncClient.Registration.fromOnEventRegistrations
      ->Array.map(input => (
        input.blockFields->Array.toSorted(String.compare),
        input.transactionFields->Array.toSorted(String.compare),
      ))
    t.expect(inputs).toEqual([
      (["Number", "ParentHash", "Timestamp"], []),
      (["Number", "Timestamp"], ["GasUsed"]),
    ])
  })

  it("rejects a field name that isn't an EVM block or transaction field", t => {
    let message = fields =>
      try {
        register(() => setHandler(~eventOptions={fields: fields}, makeHandler()))->ignore
        "the registration to fail, but it succeeded"
      } catch {
      | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
      }
    t.expect((message({block: ["notAField"]}), message({transaction: ["notAField"]}))).toEqual((
      `Invalid "notAField" field in the fields.block option of the "Transfer" event registration on contract "ERC20". Valid block fields: number, timestamp, hash, parentHash, nonce, sha3Uncles, logsBloom, transactionsRoot, stateRoot, receiptsRoot, miner, difficulty, totalDifficulty, extraData, size, gasLimit, gasUsed, uncles, baseFeePerGas, blobGasUsed, excessBlobGas, parentBeaconBlockRoot, withdrawalsRoot, l1BlockNumber, sendCount, sendRoot, mixHash.`,
      `Invalid "notAField" field in the fields.transaction option of the "Transfer" event registration on contract "ERC20". Valid transaction fields: transactionIndex, hash, from, to, gas, gasPrice, maxPriorityFeePerGas, maxFeePerGas, cumulativeGasUsed, effectiveGasPrice, gasUsed, input, nonce, value, v, r, s, contractAddress, logsBloom, root, status, yParity, maxFeePerBlobGas, blobVersionedHashes, type, l1Fee, l1GasPrice, l1GasUsed, l1FeeScalar, gasUsedForL1, accessList, authorizationList.`,
    ))
  })

  it("rejects a field an RPC-synced chain can't deliver", t => {
    let message = try {
      register(~config=rpcConfig, () =>
        setHandler(~eventOptions=withFields(~transaction=["accessList"], ()), makeHandler())
      )->ignore
      "the registration to fail, but it succeeded"
    } catch {
    | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
    }
    t.expect(message).toBe(
      `The "accessList" transaction field selected for the "Transfer" event on contract "ERC20" is unavailable for indexing via RPC. Remove it from the field selection, or index chain 1 via HyperSync.`,
    )
  })

  // The registration is dropped for this chain before it reaches the source, so
  // the chain's RPC limits never apply to it.
  it("skips the RPC check for a registration whose where opts out of the chain", t => {
    let registrations = register(~config=rpcConfig, () =>
      setHandler(
        ~eventOptions={
          where: %raw(`() => false`),
          fields: {transaction: ["accessList"]},
        },
        makeHandler(),
      )
    )
    t.expect(registrations->selections(~chainKey="1")).toEqual([])
  })

  it("rejects a fields option that isn't an array of names", t => {
    let message = try {
      register(() =>
        setHandler(~eventOptions={fields: {block: %raw(`"parentHash"`)}}, makeHandler())
      )->ignore
      "the registration to fail, but it succeeded"
    } catch {
    | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
    }
    t.expect(message).toBe(
      `The fields.block option of the "Transfer" event registration on contract "ERC20" must be an array of field names.`,
    )
  })

  it("rejects a duplicated field name", t => {
    let message = try {
      register(() =>
        setHandler(~eventOptions=withFields(~block=["parentHash", "parentHash"], ()), makeHandler())
      )->ignore
      "the registration to fail, but it succeeded"
    } catch {
    | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
    }
    t.expect(message).toBe(
      `Duplicate "parentHash" field in the fields.block option of the "Transfer" event registration on contract "ERC20".`,
    )
  })
})
