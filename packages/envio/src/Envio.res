// The file with public API.
// Should be an entry point after we get rid of the generated project.
// Don't forget to keep index.d.ts in sync with this file.

// Ecosystem-scoped argument records for `indexer.onBlock` / `indexer.onSlot`
// handlers. Mirror the TypeScript shapes in `packages/envio/index.d.ts`
// (`EvmOnBlockHandlerArgs`, `FuelOnBlockHandlerArgs`, `SvmOnSlotHandlerArgs`).
type evmOnBlockArgs<'context> = {
  block: {number: int},
  context: 'context,
}

type fuelOnBlockArgs<'context> = {
  block: {height: int},
  context: 'context,
}

type svmOnSlotArgs<'context> = {
  slot: int,
  context: 'context,
}

/** Borsh-decoded instruction view. Present whenever a `ProgramSchema` was
 attached to the program (bundled schema, Anchor IDL, or hand-written YAML
 `accounts`/`args`). Absent (`None`) when no schema applied or the
 discriminator didn't match any registered instruction. */
type svmInstructionParams = {
  /** Schema-declared instruction name (matches the codegen module suffix). */
  name: string,
  /** Borsh-decoded args. `JSON.Object({})` for no-arg instructions
   (e.g. `VerifyCollection`). POC types this as raw `JSON.t`; cast at the
   handler with `(json :> MyArgsType)` until typed codegen lands. */
  args: JSON.t,
  /** Named accounts in schema order. Keys are exactly the schema-declared
   names; values are base58 pubkey strings. */
  accounts: dict<string>,
  /** Accounts beyond the schema's named list (Anchor `remaining_accounts`,
   IDL drift). `[]` when counts match. */
  extraAccounts: array<string>,
}

type svmTokenBalance = {
  account?: SvmTypes.Pubkey.t,
  mint?: SvmTypes.Pubkey.t,
  owner?: SvmTypes.Pubkey.t,
  preAmount?: string,
  postAmount?: string,
}

type svmTransaction = {
  transactionIndex?: int,
  signatures: array<string>,
  feePayer?: SvmTypes.Pubkey.t,
  success?: bool,
  err?: string,
  fee?: bigint,
  computeUnitsConsumed?: bigint,
  accountKeys: array<SvmTypes.Pubkey.t>,
  recentBlockhash?: string,
  version?: string,
  tokenBalances?: array<svmTokenBalance>,
}

type svmLog = {
  kind: string,
  message: string,
}

/** Block context for a matched instruction. `time`/`hash` follow the
 EVM/Fuel field names so the shared `Ecosystem.t` getters in `Svm.res` read
 them uniformly. `slot`/`time` come from the item; the remaining fields are
 materialised from the per-chain block store at batch prep. */
type svmInstructionBlock = {
  /** Slot this instruction's block was matched in. */
  slot: int,
  /** Unix block time (seconds). `0` when HyperSync didn't return a block
   for this instruction's slot. */
  time: int,
  /** Block hash. Empty when HyperSync didn't return a block for this slot. */
  hash: string,
  /** Block height (distinct from slot). Absent when HyperSync didn't return a
   block for this slot, or the upstream omitted it. */
  blockHeight?: int,
  /** Slot of the parent block. */
  parentSlot?: int,
  /** Hash of the parent block. */
  parentBlockhash?: string,
}

/** The per-instruction payload handlers receive as their `instruction`
 argument. Carries the matched instruction's own fields plus the
 program/instruction names, parent transaction, scoped logs, and block. */
type svmInstruction = {
  /** Program name as declared under `programs[].name` in `config.yaml`. */
  programName: string,
  /** Instruction name as declared under `instructions[].name` in
   `config.yaml`. */
  instructionName: string,
  programId: SvmTypes.Pubkey.t,
  /** Raw instruction bytes as `0x`-prefixed hex. */
  data: string,
  accounts: array<SvmTypes.Pubkey.t>,
  /** Path through the call tree: `[outerIndex]` for top-level instructions,
   appended child indices for inner CPI calls. */
  instructionAddress: array<int>,
  isInner: bool,
  /** Discriminator prefixes pre-extracted by HyperSync. Each is `Some` only
   when the underlying instruction is at least that long. */
  d1?: string,
  d2?: string,
  d4?: string,
  d8?: string,
  /** Borsh-decoded params view. See [[svmInstructionParams]]. */
  params?: svmInstructionParams,
  /** Parent transaction. Carries only the fields selected via
   `field_selection.transaction_fields`; absent when none are selected. */
  transaction?: svmTransaction,
  /** Program log entries scoped to this instruction. Absent when the
   per-instruction `include_logs` flag is `false`. */
  logs?: array<svmLog>,
  block: svmInstructionBlock,
}

/** Arguments passed to handlers registered via `indexer.onInstruction`. */
type svmOnInstructionArgs<'context> = {
  instruction: svmInstruction,
  context: 'context,
}

// Internal-only type for the `indexer.onBlock` (and SVM `onSlot`) `where`
// callback argument. The canonical TypeScript shape lives in
// `packages/envio/index.d.ts`; the ReScript declaration here is free to
// diverge.
type onBlockWhereArgs<'chain> = {chain: 'chain}

// `where` returns a value interpreted at runtime by `Main.res::onBlockHandlerFn`:
//   - `false` → skip this chain
//   - `true` / omit → register on this chain with no extra filter
//   - a filter object whose shape is ecosystem-specific (see the `Evm*` /
//     `Fuel*` / `Svm*` `OnBlock`/`OnSlot` types in `packages/envio/index.d.ts`)
type onBlockOptions<'chain> = {
  name: string,
  where?: onBlockWhereArgs<'chain> => unknown,
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

type logger = {
  debug: 'params. (string, ~params: {..} as 'params=?) => unit,
  info: 'params. (string, ~params: {..} as 'params=?) => unit,
  warn: 'params. (string, ~params: {..} as 'params=?) => unit,
  error: 'params. (string, ~params: {..} as 'params=?) => unit,
  errorWithExn: (string, exn) => unit,
}

@@warning("-30") // Duplicated type names (input)
type rec effect<'input, 'output>
@unboxed
and rateLimitDuration =
  | @as("second") Second
  | @as("minute") Minute
  | Milliseconds(int)
@unboxed
and rateLimit =
  | @as(false) Disable
  | Enable({calls: int, per: rateLimitDuration})
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
and effectContext = {
  log: logger,
  effect: 'input 'output. (effect<'input, 'output>, 'input) => promise<'output>,
  mutable cache: bool,
}
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
        windowStartTime: Date.now(),
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

type evmSimulateItem = {
  contract: string,
  event: string,
  params?: JSON.t,
  srcAddress?: Address.t,
  logIndex?: int,
  block?: Internal.evmBlockInput,
  transaction?: Internal.evmTransactionInput,
}

type fuelSimulateItem = {
  contract: string,
  event: string,
  params: JSON.t,
  srcAddress?: Address.t,
  logIndex?: int,
  block?: fuelBlockInput,
  transaction?: fuelTransactionInput,
}

// Detects contexts where a full-screen TUI is counter-productive: piped/redirected
// stdout, CI, and coding agents. `CLAUDECODE` is set by Claude Code; `CI` is the
// de-facto convention across CI providers; `TERM=dumb` is set by editors/tools
// that emulate a terminal without ANSI support.
@val external stdoutIsTty: option<bool> = "process.stdout.isTTY"
let isNonInteractive = () => {
  let env = NodeJs.Process.process.env
  stdoutIsTty !== Some(true) ||
  env->Dict.get("CLAUDECODE")->Option.isSome ||
  env->Dict.get("CI")->Option.isSome ||
  env->Dict.get("TERM") === Some("dumb")
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
      ]->Array.map(Address.Evm.fromStringOrThrow)
    let defaultAddress = mockAddresses->Array.getUnsafe(0)
  }
}
