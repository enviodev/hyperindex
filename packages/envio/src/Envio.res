// The file with public API.
// Should be an entry point after we get rid of the generated project.
// Don't forget to keep index.d.ts in sync with this file.

@genType
type blockEvent = {number: int}

@genType
type fuelBlockEvent = {height: int}

@genType
type svmOnBlockArgs<'context> = {slot: int, context: 'context}

@genType
type onBlockArgs<'block, 'context> = {
  block: 'block,
  context: 'context,
}

@genType
type onBlockOptions<'chain> = {
  name: string,
  chain: 'chain,
  interval?: int,
  startBlock?: int,
  endBlock?: int,
}

type whereOperator<'fieldType> = {
  /** Matches entities where the field equals the given value. */
  _eq?: 'fieldType,
  /** Matches entities where the field is strictly greater than the given value. */
  _gt?: 'fieldType,
  /** Matches entities where the field is strictly less than the given value. */
  _lt?: 'fieldType,
  /** Matches entities where the field is greater than or equal to the given value. */
  _gte?: 'fieldType,
  /** Matches entities where the field is less than or equal to the given value. */
  _lte?: 'fieldType,
  /** Matches entities where the field equals any of the given values. */
  _in?: array<'fieldType>,
}

@genType.import(("./Types.ts", "Logger"))
type logger = {
  debug: 'params. (string, ~params: {..} as 'params=?) => unit,
  info: 'params. (string, ~params: {..} as 'params=?) => unit,
  warn: 'params. (string, ~params: {..} as 'params=?) => unit,
  error: 'params. (string, ~params: {..} as 'params=?) => unit,
  errorWithExn: (string, exn) => unit,
}

@@warning("-30") // Duplicated type names (input)
@genType.import(("./Types.ts", "Effect"))
type rec effect<'input, 'output>
@genType @unboxed
and rateLimitDuration =
  | @as("second") Second
  | @as("minute") Minute
  | Milliseconds(int)
@genType @unboxed
and rateLimit =
  | @as(false) Disable
  | Enable({calls: int, per: rateLimitDuration})
@genType
and effectOptions<'input, 'output> = {
  /** The name of the effect. Used for logging and debugging. */
  name: string,
  /** The input schema of the effect. */
  input: S.t<'input>,
  /** The output schema of the effect. */
  output: S.t<'output>,
  /** Rate limit for the effect. Set to false to disable or provide {calls: number, per: "second" | "minute"} to enable. */
  rateLimit: rateLimit,
  /** Whether the effect should be cached. */
  cache?: bool,
}
@genType.import(("./Types.ts", "EffectContext"))
and effectContext = {
  log: logger,
  effect: 'input 'output. (effect<'input, 'output>, 'input) => promise<'output>,
  mutable cache: bool,
}
@genType
and effectArgs<'input> = {
  input: 'input,
  context: effectContext,
}
@@warning("+30")

let durationToMs = (duration: rateLimitDuration) =>
  switch duration {
  | Second => 1000
  | Minute => 60000
  | Milliseconds(ms) => ms
  }

let createEffect = (
  options: effectOptions<'input, 'output>,
  handler: effectArgs<'input> => promise<'output>,
) => {
  let outputSchema =
    S.schema(_ => options.output)->(Utils.magic: S.t<S.t<'output>> => S.t<Internal.effectOutput>)
  let itemSchema = S.schema((s): Internal.effectCacheItem => {
    id: s.matches(S.string),
    output: s.matches(outputSchema),
  })
  {
    name: options.name,
    handler: handler->(
      Utils.magic: (effectArgs<'input> => promise<'output>) => Internal.effectArgs => promise<
        Internal.effectOutput,
      >
    ),
    activeCallsCount: 0,
    prevCallStartTimerRef: %raw(`null`),
    // This is the way to make the createEffect API
    // work without the need for users to call S.schema themselves,
    // but simply pass the desired object/tuple/etc.
    // If they pass a schem, it'll also work.
    input: S.schema(_ => options.input)->(
      Utils.magic: S.t<S.t<'input>> => S.t<Internal.effectInput>
    ),
    output: outputSchema,
    storageMeta: {
      table: Internal.makeCacheTable(~effectName=options.name),
      outputSchema,
      itemSchema,
    },
    defaultShouldCache: switch options.cache {
    | Some(true) => true
    | _ => false
    },
    rateLimit: switch options.rateLimit {
    | Disable => None
    | Enable({calls, per}) =>
      Some({
        callsPerDuration: calls,
        durationMs: per->durationToMs,
        availableCalls: calls,
        windowStartTime: Js.Date.now(),
        queueCount: 0,
        nextWindowPromise: None,
      })
    },
  }->(Utils.magic: Internal.effect => effect<'input, 'output>)
}

type fuelBlockInput = {
  id?: string,
  height?: int,
  time?: int,
}

type fuelTransactionInput = {id?: string}

type evmSimulateEventItem = {
  contract: string,
  event: string,
  params?: Js.Json.t,
  srcAddress?: Address.t,
  logIndex?: int,
  block?: Internal.evmBlockInput,
  transaction?: Internal.evmTransactionInput,
}

type fuelSimulateEventItem = {
  contract: string,
  event: string,
  params: Js.Json.t,
  srcAddress?: Address.t,
  logIndex?: int,
  block?: fuelBlockInput,
  transaction?: fuelTransactionInput,
}

module TestHelpers = {
  module Addresses = {
    let mockAddresses =
      [
        "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
        "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
        "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
        "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
        "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65",
        "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc",
        "0x976EA74026E726554dB657fA54763abd0C3a0aa9",
        "0x14dC79964da2C08b23698B3D3cc7Ca32193d9955",
        "0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f",
        "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720",
        "0xBcd4042DE499D14e55001CcbB24a551F3b954096",
        "0x71bE63f3384f5fb98995898A86B02Fb2426c5788",
        "0xFABB0ac9d68B0B445fB7357272Ff202C5651694a",
        "0x1CBd3b2770909D4e10f157cABC84C7264073C9Ec",
        "0xdF3e18d64BC6A983f673Ab319CCaE4f1a57C7097",
        "0xcd3B766CCDd6AE721141F452C550Ca635964ce71",
        "0x2546BcD3c84621e976D8185a91A922aE77ECEc30",
        "0xbDA5747bFD65F08deb54cb465eB87D40e51B197E",
        "0xdD2FD4581271e230360230F9337D5c0430Bf44C0",
        "0x8626f6940E2eb28930eFb4CeF49B2d1F2C9C1199",
      ]->Belt.Array.map(Address.Evm.fromStringOrThrow)
    let defaultAddress = mockAddresses[0]
  }
}
