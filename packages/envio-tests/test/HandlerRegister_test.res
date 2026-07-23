open Vitest

// Covers `HandlerRegister`'s multiple-registrations-per-event behaviour:
// every `onEvent` becomes its own registration, a `contractRegister` merges
// into a handler registration (either order) when their filters match, and
// unlimited wildcard registrations are allowed.

let config = MockIndexerConfig.parseYaml(`
name: handler-register-test
contracts:
  - name: ERC20
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
      - event: Approval(address indexed owner, address indexed spender, uint256 value)
  - name: ERC721
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    rpc:
      url: https://eth.com
      for: sync
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1111111111111111111111111111111111111111"
      - name: ERC721
        address: "0x2222222222222222222222222222222222222222"
`).config

// Same contracts/events as `config` but a different chain id. Used to verify
// that registration intents are chain-independent: registering under `config`
// (chain 1) still materializes registrations when `finishRegistration` runs
// for chain 137 (mirrors TestIndexer narrowing `chainMap` per run).
let config137 = MockIndexerConfig.parseYaml(`
name: handler-register-test-137
contracts:
  - name: ERC20
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
      - event: Approval(address indexed owner, address indexed spender, uint256 value)
chains:
  - id: 137
    rpc:
      url: https://polygon.com
      for: sync
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1111111111111111111111111111111111111111"
`).config

// raw_events enabled, single chain. Used to verify that a `where: false` event
// is excluded entirely while a handler-less event still gets a bare raw-events
// registration.
let configWithRawEvents = MockIndexerConfig.parseYaml(`
name: handler-register-raw-events
raw_events: true
contracts:
  - name: ERC20
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
      - event: Approval(address indexed owner, address indexed spender, uint256 value)
chains:
  - id: 1
    rpc:
      url: https://eth.com
      for: sync
    start_block: 0
    contracts:
      - name: ERC20
        address: "0x1111111111111111111111111111111111111111"
`).config

// Each handler/contractRegister is a distinct function so registrations can be
// identified by reference in assertions.
let makeHandler = (): Internal.handler => %raw(`() => Promise.resolve()`)
let makeContractRegister = (): Internal.contractRegister => %raw(`() => Promise.resolve()`)

let setHandler = (~contractName="ERC20", ~eventName="Transfer", ~eventOptions=?, handler) =>
  HandlerRegister.setHandler(
    ~contractName,
    ~eventName,
    handler->(Utils.magic: Internal.handler => Internal.genericHandler<_>),
    ~eventOptions,
  )

let setContractRegister = (
  ~contractName="ERC20",
  ~eventName="Transfer",
  ~eventOptions=?,
  contractRegister,
) =>
  HandlerRegister.setContractRegister(
    ~contractName,
    ~eventName,
    contractRegister->(Utils.magic: Internal.contractRegister => Internal.genericContractRegister<_>),
    ~eventOptions,
  )

// Registrations for the given event on chain 1, described as
// `(handlerLabel, contractRegisterLabel, index)` where labels resolve the
// stored function back to the ones registered below.
let describeRegistrations = (
  registrations: HandlerRegister.registrationsByChainId,
  ~chainKey="1",
  ~contractName="ERC20",
  ~eventName="Transfer",
  ~labels: array<(Internal.handler, string)>,
  ~crLabels: array<(Internal.contractRegister, string)>,
) => {
  let handlerLabel = h =>
    labels->Array.find(((fn, _)) => fn === h)->Option.map(((_, label)) => label)->Option.getOr("?")
  let crLabel = cr =>
    crLabels
    ->Array.find(((fn, _)) => fn === cr)
    ->Option.map(((_, label)) => label)
    ->Option.getOr("?")
  let chainRegistrations: HandlerRegister.chainRegistrations =
    registrations->Utils.Dict.dangerouslyGetNonOption(chainKey)->Option.getOrThrow
  chainRegistrations.onEventRegistrations
  ->Array.filter(reg =>
    reg.eventConfig.contractName === contractName && reg.eventConfig.name === eventName
  )
  ->Array.map(reg => (
    reg.handler->Option.map(handlerLabel),
    reg.contractRegister->Option.map(crLabel),
    reg.index,
  ))
}

let register = fn => {
  HandlerRegister.resetOnEventRegistrations()
  HandlerRegister.startRegistration(~config)
  fn()
  HandlerRegister.finishRegistration(~config)
}

describe("HandlerRegister multiple registrations", () => {
  it("keeps two onEvent handlers as separate registrations in registration order", t => {
    let h1 = makeHandler()
    let h2 = makeHandler()
    let registrations = register(() => {
      setHandler(h1)
      setHandler(h2)
    })
    t.expect(
      registrations->describeRegistrations(
        ~labels=[(h1, "h1"), (h2, "h2")],
        ~crLabels=[],
      ),
    ).toEqual([(Some("h1"), None, 0), (Some("h2"), None, 1)])
  })

  it("merges a contractRegister into a handler with matching filter", t => {
    let h1 = makeHandler()
    let cr1 = makeContractRegister()
    let registrations = register(() => {
      setHandler(h1)
      setContractRegister(cr1)
    })
    t.expect(
      registrations->describeRegistrations(
        ~labels=[(h1, "h1")],
        ~crLabels=[(cr1, "cr1")],
      ),
    ).toEqual([(Some("h1"), Some("cr1"), 0)])
  })

  it("merges a handler into an earlier contractRegister, keeping the handler's slot", t => {
    let h1 = makeHandler()
    let cr1 = makeContractRegister()
    let registrations = register(() => {
      setContractRegister(cr1)
      setHandler(h1)
    })
    t.expect(
      registrations->describeRegistrations(
        ~labels=[(h1, "h1")],
        ~crLabels=[(cr1, "cr1")],
      ),
    ).toEqual([(Some("h1"), Some("cr1"), 0)])
  })

  it("keeps a handler and contractRegister with different `where` filters separate", t => {
    let h1 = makeHandler()
    let cr1 = makeContractRegister()
    let registrations = register(() => {
      setHandler(h1)
      setContractRegister(
        ~eventOptions={
          where: %raw(`{"params": {"from": "0x1111111111111111111111111111111111111111"}}`),
        },
        cr1,
      )
    })
    t.expect(
      registrations->describeRegistrations(
        ~labels=[(h1, "h1")],
        ~crLabels=[(cr1, "cr1")],
      ),
    ).toEqual([(Some("h1"), None, 0), (None, Some("cr1"), 1)])
  })

  it("does not merge a wildcard handler with a non-wildcard contractRegister", t => {
    let h1 = makeHandler()
    let cr1 = makeContractRegister()
    let registrations = register(() => {
      setHandler(~eventOptions={wildcard: true}, h1)
      setContractRegister(cr1)
    })
    t.expect(
      registrations->describeRegistrations(
        ~labels=[(h1, "h1")],
        ~crLabels=[(cr1, "cr1")],
      ),
    ).toEqual([(Some("h1"), None, 0), (None, Some("cr1"), 1)])
  })

  it("allows multiple wildcard registrations sharing a signature", t => {
    let h1 = makeHandler()
    let h2 = makeHandler()
    let registrations = register(() => {
      setHandler(~contractName="ERC20", ~eventOptions={wildcard: true}, h1)
      setHandler(~contractName="ERC721", ~eventOptions={wildcard: true}, h2)
    })
    t.expect((
      registrations->describeRegistrations(
        ~contractName="ERC20",
        ~labels=[(h1, "h1")],
        ~crLabels=[],
      ),
      registrations->describeRegistrations(
        ~contractName="ERC721",
        ~labels=[(h2, "h2")],
        ~crLabels=[],
      ),
    )).toEqual(([(Some("h1"), None, 0)], [(Some("h2"), None, 1)]))
  })

  it("materializes registrations for a chain not present during registration", t => {
    // Register under `config` (chain 1), then finish for `config137` (chain 137)
    // without re-registering — intents are chain-independent, so chain 137 must
    // still get the handler (the TestIndexer chainMap-narrowing case).
    let h1 = makeHandler()
    HandlerRegister.resetOnEventRegistrations()
    HandlerRegister.startRegistration(~config)
    setHandler(h1)
    let _ = HandlerRegister.finishRegistration(~config)
    let registrations137 = HandlerRegister.finishRegistration(~config=config137)
    t.expect(
      registrations137->describeRegistrations(~chainKey="137", ~labels=[(h1, "h1")], ~crLabels=[]),
    ).toEqual([(Some("h1"), None, 0)])
  })

  it("replays pre-registered handlers in source order, not reversed", t => {
    // Handlers imported before `startRegistration` are queued in `preRegistered`
    // and replayed at start. That replay order is the dispatch order, so two
    // handlers on one event must keep their source order (h1 before h2).
    let h1 = makeHandler()
    let h2 = makeHandler()
    HandlerRegister.resetOnEventRegistrations()
    setHandler(h1)
    setHandler(h2)
    HandlerRegister.startRegistration(~config)
    let registrations = HandlerRegister.finishRegistration(~config)
    t.expect(
      registrations->describeRegistrations(~labels=[(h1, "h1"), (h2, "h2")], ~crLabels=[]),
    ).toEqual([(Some("h1"), None, 0), (Some("h2"), None, 1)])
  })

  it("invokes a `where` callback once per chain, even across repeated finishes", t => {
    // The `where` callback is resolved once per chain and cached on the intent,
    // so re-materializing registrations (finishRegistration, simulate) must not
    // call it again.
    let calls = ref(0)
    let h1 = makeHandler()
    let whereFn = _ => {
      calls := calls.contents + 1
      true
    }
    HandlerRegister.resetOnEventRegistrations()
    HandlerRegister.startRegistration(~config)
    setHandler(~eventOptions={where: whereFn->Obj.magic}, h1)
    let _ = HandlerRegister.finishRegistration(~config)
    let _ = HandlerRegister.finishRegistration(~config)
    t.expect(calls.contents).toBe(1)
  })

  it("excludes a where:false event but backfills a handler-less event for raw events", t => {
    // Transfer's handler opts out of the chain via `where: false` → excluded
    // entirely (no raw-events registration). Approval has no handler → with raw
    // events enabled it gets a bare (handler-less) registration.
    let h1 = makeHandler()
    HandlerRegister.resetOnEventRegistrations()
    HandlerRegister.startRegistration(~config=configWithRawEvents)
    setHandler(~eventName="Transfer", ~eventOptions={where: %raw(`() => false`)}, h1)
    let registrations = HandlerRegister.finishRegistration(~config=configWithRawEvents)
    t.expect((
      registrations->describeRegistrations(
        ~eventName="Transfer",
        ~labels=[(h1, "h1")],
        ~crLabels=[],
      ),
      registrations->describeRegistrations(~eventName="Approval", ~labels=[], ~crLabels=[]),
    )).toEqual(([], [(None, None, 0)]))
  })
})
