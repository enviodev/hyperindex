open Vitest

// Covers the per-chain immediate resolution in `HandlerRegister`: every
// `onEvent` becomes its own registration (no composing, no duplicate error),
// invalid `where`/onBlock options still throw at the user's registration call
// site, and `preRegistered` callbacks replayed by `startRegistration` run
// through the same code path.
//
// This file must not import the handler fixtures — it drives the global
// registry lifecycle itself, relying on vitest's per-file isolation.

let config = Config.load()

let noopHandler = async _ => ()

let eventOptions = (~where: JSON.t): option<Internal.eventOptions<JSON.t>> =>
  Some({wildcard: true, where})

// Registered before `startRegistration` → lands in `preRegistered` and
// replays inside `startRegistration`, resolving the `where` per chain there.
HandlerRegister.setHandler(
  ~contractName="EventFiltersTest",
  ~eventName="Transfer",
  noopHandler,
  ~eventOptions=eventOptions(
    ~where=%raw(`({chain: _chain}) => ({params: {from: "0x0000000000000000000000000000000000000000"}})`),
  ),
)
HandlerRegister.startRegistration(~config)

describe("HandlerRegister — every onEvent registers separately", () => {
  it("a second handler with an equal resolution registers without composing or throwing", t => {
    t.expect(() =>
      HandlerRegister.setHandler(
        ~contractName="EventFiltersTest",
        ~eventName="Transfer",
        noopHandler,
        ~eventOptions=eventOptions(
          ~where=%raw(`({chain: _chain}) => ({params: {from: "0x0000000000000000000000000000000000000000"}})`),
        ),
      )
    ).not.toThrow()
  })

  it("a handler with a different resolution registers separately without throwing", t => {
    t.expect(() =>
      HandlerRegister.setHandler(
        ~contractName="EventFiltersTest",
        ~eventName="Transfer",
        noopHandler,
        ~eventOptions=eventOptions(
          ~where=%raw(`({chain: _chain}) => ({params: {to: "0x0000000000000000000000000000000000000000"}})`),
        ),
      )
    ).not.toThrow()
  })

  it("an invalid where throws at the registration call site", t => {
    t.expect(() =>
      HandlerRegister.setHandler(
        ~contractName="EventFiltersTest",
        ~eventName="EmptyFiltersArray",
        noopHandler,
        ~eventOptions=eventOptions(
          ~where=%raw(`{params: {nonExistingParam: "0x0000000000000000000000000000000000000000"}}`),
        ),
      )
    ).toThrowErrorEqual(
      `Invalid where configuration. The event doesn't have an indexed parameter "nonExistingParam" and can't use it for filtering`,
    )
  })
})

describe("HandlerRegister — onBlock validation at registration", () => {
  let noopBlockHandler = async (_: Internal.onBlockArgs) => ()

  // A minimal chains object: the predicates below only read `chain.id`.
  let getChainsObject = (config: Config.t) =>
    config.chainMap
    ->ChainMap.values
    ->Array.map(chainConfig => (
      chainConfig.id->Int.toString,
      {"id": chainConfig.id}->(Utils.magic: {"id": int} => unknown),
    ))
    ->Dict.fromArray

  it("throws when where is not a function", t => {
    t.expect(() =>
      HandlerRegister.registerOnBlock(
        ~name="badWhere",
        ~where=%raw(`{block: {number: {_gte: 10}}}`),
        ~handler=noopBlockHandler,
        ~getChainsObject,
      )
    ).toThrowErrorEqual(
      `\`indexer.onBlock("badWhere")\` expected \`where\` to be a function or omitted, but got object.`,
    )
  })

  it("throws when where returns a filter with unknown fields", t => {
    t.expect(() =>
      HandlerRegister.registerOnBlock(
        ~name="typoFilter",
        ~where=%raw(`() => ({block: {number: {_gt: 10}}})`),
        ~handler=noopBlockHandler,
        ~getChainsObject,
      )
    ).toThrowErrorEqual(
      `\`indexer.onBlock("typoFilter")\` \`where\` returned an invalid filter: RescriptSchemaError: Failed parsing at root. Reason: Encountered disallowed excess key "_gt" on an object`,
    )
  })

  it("throws when startBlock is below the chain start block", t => {
    t.expect(() =>
      HandlerRegister.registerOnBlock(
        ~name="tooEarly",
        ~where=%raw(`({chain}) => chain.id === 137 ? {block: {number: {_gte: 0}}} : false`),
        ~handler=noopBlockHandler,
        ~getChainsObject,
      )
    ).toThrowErrorEqual(
      `The start block for onBlock handler "tooEarly" is less than the chain start block (1). This is not supported yet.`,
    )
  })
})
