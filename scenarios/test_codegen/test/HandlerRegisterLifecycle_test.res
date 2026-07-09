open Vitest

// Covers the per-chain immediate resolution in `HandlerRegister`: duplicate
// registrations are compared on the resolved `where` structure (not the
// callback reference), invalid `where`/onBlock options throw at the user's
// registration call site, and `preRegistered` callbacks replayed by
// `startRegistration` run through the same code path.
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

describe("HandlerRegister — duplicate registrations compare resolved where", () => {
  it("a distinct callback with an equal resolution composes instead of throwing", t => {
    HandlerRegister.setHandler(
      ~contractName="EventFiltersTest",
      ~eventName="Transfer",
      noopHandler,
      ~eventOptions=eventOptions(
        ~where=%raw(`({chain: _chain}) => ({params: {from: "0x0000000000000000000000000000000000000000"}})`),
      ),
    )
    t.expect(
      HandlerRegister.getHandler(
        ~contractName="EventFiltersTest",
        ~eventName="Transfer",
      )->Option.isSome,
    ).toBe(true)
  })

  it("a callback with a different resolution throws at the registration call site", t => {
    t.expect(() =>
      HandlerRegister.setHandler(
        ~contractName="EventFiltersTest",
        ~eventName="Transfer",
        noopHandler,
        ~eventOptions=eventOptions(
          ~where=%raw(`({chain: _chain}) => ({params: {to: "0x0000000000000000000000000000000000000000"}})`),
        ),
      )
    ).toThrowError(
      "Cannot register a second handler with different options. Make sure all handlers for the same event use identical options (wildcard, where) for EventFiltersTest.Transfer",
    )
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
    ).toThrowError(
      `Invalid where configuration. The event doesn't have an indexed parameter "nonExistingParam" and can't use it for filtering`,
    )
  })
})

describe("HandlerRegister — onBlock validation at registration", () => {
  let noopBlockHandler = async (_: Internal.onBlockArgs) => ()

  it("throws for a chainId that is not in the config", t => {
    t.expect(() =>
      HandlerRegister.registerOnBlock(
        ~name="unknownChain",
        ~chainId=424242,
        ~interval=1,
        ~startBlock=None,
        ~endBlock=None,
        ~handler=noopBlockHandler,
      )
    ).toThrowError(
      `The onBlock handler "unknownChain" is registered for chain 424242 which is not in the config.`,
    )
  })

  it("throws when startBlock is below the chain start block", t => {
    t.expect(() =>
      HandlerRegister.registerOnBlock(
        ~name="tooEarly",
        ~chainId=137,
        ~interval=1,
        ~startBlock=Some(0),
        ~endBlock=None,
        ~handler=noopBlockHandler,
      )
    ).toThrowError(
      `The start block for onBlock handler "tooEarly" is less than the chain start block (1). This is not supported yet.`,
    )
  })
})
