open Vitest

// Invalid `indexer.onBlock` options throw at the user's registration call site.
//
// This file must not import the handler fixtures — it drives the global
// registry lifecycle itself, relying on vitest's per-file isolation.

let config = TestConfig.fromUserApi(`
name: handler-register-lifecycle
contracts:
  - name: EventFiltersTest
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 amount)
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: EventFiltersTest
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
  - id: 137
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: EventFiltersTest
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
`)

HandlerRegister.startRegistration(~logger=Logger.makeInMemory(), ~config)

describe("HandlerRegister — onBlock validation at registration", () => {
  let noopBlockHandler = async (_: Internal.onBlockArgs) => ()

  // Stands in for the object `Main` builds: the predicates below read
  // `chain.id`, and onBlock validation reads `chain.startBlock` - which is
  // where the resolved `start_block: latest` block lives in a real run.
  let getChainsObject = (config: Config.t) =>
    config.chainMap
    ->ChainMap.values
    ->Array.map(chainConfig => (
      chainConfig.id->ChainId.toString,
      {"id": chainConfig.id, "startBlock": chainConfig->Config.startBlockOrZero}->(
        Utils.magic: {"id": ChainId.t, "startBlock": int} => unknown
      ),
    ))
    ->Dict.fromArray

  it("throws when where is not a function", t => {
    t->toThrowErrorEqual(
      () =>
        HandlerRegister.registerOnBlock(
          ~name="badWhere",
          ~where=%raw(`{block: {number: {_gte: 10}}}`),
          ~fields=%raw(`undefined`),
          ~handler=noopBlockHandler,
          ~getChainsObject,
        ),
      `\`indexer.onBlock("badWhere")\` expected \`where\` to be a function or omitted, but got object.`,
    )
  })

  it("throws when where returns a filter with unknown fields", t => {
    t->toThrowErrorEqual(
      () =>
        HandlerRegister.registerOnBlock(
          ~name="typoFilter",
          ~where=%raw(`() => ({block: {number: {_gt: 10}}})`),
          ~fields=%raw(`undefined`),
          ~handler=noopBlockHandler,
          ~getChainsObject,
        ),
      `\`indexer.onBlock("typoFilter")\` \`where\` returned an invalid filter: RescriptSchemaError: Failed parsing at root. Reason: Encountered disallowed excess key "_gt" on an object`,
    )
  })

  it("throws when startBlock is below the chain start block", t => {
    t->toThrowErrorEqual(
      () =>
        HandlerRegister.registerOnBlock(
          ~name="tooEarly",
          ~where=%raw(`({chain}) => chain.id === 137 ? {block: {number: {_gte: 0}}} : false`),
          ~fields=%raw(`undefined`),
          ~handler=noopBlockHandler,
          ~getChainsObject,
        ),
      `The start block for onBlock handler "tooEarly" is less than the chain start block (1). This is not supported yet.`,
    )
  })
})
