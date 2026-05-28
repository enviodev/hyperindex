# Stage 7b + 7c: design decisions (POC)

Living doc. Expect these to change as the surface lands and we iterate. Last
updated 2026-05-21.

Stage 7b adds Borsh-decoded `event.instruction.decoded.args` + named
`event.instruction.decoded.accounts.<name>` on the handler arg, powered by the
just-published `hypersync-client-solana 0.0.3-rc.1` decoder. Stage 7c adds an
`envio init --idl <path>` flag that scaffolds the YAML automatically from an
Anchor IDL. Both ship in one PR.

## Decision 1: schema lookup — eager handle, not per-instruction lookup

At `HyperSyncSolanaSource.make` time, the ReScript runtime builds **one
`ProgramSchema` per configured program** (Anchor IDL parse, bundled lookup,
or YAML-defined ad-hoc schema). The NAPI binding exposes an opaque handle
referencing that schema; `decode_instruction` takes the handle plus the raw
`data` + `accounts` and returns a `DecodedInstruction`.

**Why:**
- Schemas are immutable for the life of an indexer run; building them once
  is the obvious move.
- A `BTreeMap<String, ProgramSchema>` lookup on every instruction would
  string-hash the program id per call. For a Metaplex window with thousands
  of instructions per second that's pure overhead.

**Tradeoff:** opaque handles are slightly awkward across the NAPI boundary
(need to ensure lifetimes don't dangle). We keep them alive by stashing the
schemas in a process-global `OnceLock<Mutex<Vec<Arc<ProgramSchema>>>>` and
handing JS a stable `u32` index.

**Revisit if:** users start dynamically registering programs at runtime
(e.g. a future "factory" pattern that discovers new programs from chain).
Then we need a real handle type with explicit lifecycle.

## Decision 2: bundled-schema lookup keyed by `program_id` only

If a configured program's `program_id` is `metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s`
**and** the user has provided no `args`/`accounts`/`idl` overrides, we
silently attach the bundled Metaplex schema.

**Why:**
- One source of truth (the on-chain program id).
- No magic names that drift from on-chain reality.
- Users who *want* to override (e.g. their fork of Metaplex deployed at a
  different program id) can still declare `args`/`accounts` inline.

**Not doing (yet):** the friendly `program: TokenMetadata` shorthand the
roadmap mentioned. Adds a second lookup namespace that has to be kept in
sync with the bundled-schema set. Can layer on later as pure sugar.

**Revisit if:** we ship a meaningful number of bundled schemas (>3) and
users start asking for an autocompleteable selector.

## Decision 3: codegen emits fully typed args, not `unknown`

For each instruction's `args`, the codegen walks the schema and emits a TS
type:

| Schema       | TS type                                    |
|--------------|--------------------------------------------|
| `u8/u16/u32/i8/i16/i32` | `number`                        |
| `u64/u128/i64/i128`     | `string` (decimal `bigint`-ish) |
| `bool`                  | `boolean`                       |
| `string`                | `string`                        |
| `bytes`                 | `string` (`0x`-hex)             |
| `pubkey`, `[u8; 32]`    | `string` (base58)               |
| `option<T>`             | `T \| null`                     |
| `vec<T>`, `array<T, N>` | `T[]`                           |
| `struct { … }`          | `{ name: T; … }`                |
| `enum { A, B { … } }`   | `{ A: {} } \| { B: { … } }`     |
| `defined(T)`            | named type exported alongside   |

Pubkey accounts surface as a plain `Record<Name, string>` keyed by the
schema-declared names; `extra_accounts` stays a `string[]` for anything
beyond the named list.

**Why:**
- POC velocity matters less than POC *usefulness*. A handler that has to
  `as` cast every field is no better than today's raw `data` string.
- Mirrors viem/ethers convention for the `number` vs `string`/`bigint`
  split at the 2^53 line.

**Tradeoff:** more codegen code, more places to break when the schema
language extends. Acceptable for POC. The decoded payload is a
`serde_json::Value` at runtime regardless; the typing is purely a
compile-time hint, so a schema/runtime mismatch surfaces as a `TypeError`
in the handler, not silent corruption.

**Revisit if:** the codegen generator becomes the bottleneck for shipping
new schema features. Then we'd switch to a thinner `unknown`-plus-narrowing
approach.

## Decision 4: `accounts` and `args` are optional, `idl` is exclusive

The `Instruction` YAML gains optional `accounts: [name, ...]` and
`args: [{ name, type }, ...]` fields. The `Program` YAML gains an optional
`idl: <path>` field.

Validation rules (enforced in `system_config.rs`):
- `idl` is mutually exclusive with per-instruction `accounts`/`args`. If
  both are present, error with a clear message pointing the user at one or
  the other.
- For a bundled program id, both `idl` and per-instruction overrides are
  optional. Omitting them attaches the bundled schema.
- For a non-bundled program id with neither `idl` nor overrides,
  `decoded.args` is `{}` and `decoded.accounts` is empty. The raw
  `instruction.data` and `instruction.accounts[]` are still there;
  decoded data is purely additive.

**Why exclusive:** mixing an IDL with hand-written per-instruction overrides
is a recipe for divergence. One layer wins.

**Revisit if:** users ask for an "override one field of an IDL-derived
schema" pattern. We could allow per-instruction `args` overrides on an
IDL-derived program, applied after parse.

## Decision 5: `envio init --idl <path>` snapshots, doesn't fetch

Per the roadmap "Known limitations" section: `--idl <path>` reads a local
JSON file, parses it, and writes the instructions into `config.yaml` at
init time. We do **not** fetch from chain.

**Why:**
- Codegen needs to be deterministic and offline-runnable.
- On-chain IDLs (Anchor PDA-stored) can be stale relative to the deployed
  bytecode; an explicit snapshot makes the user the source of truth.

**Revisit:** the roadmap already calls this out. The long-term fix is a
`--idl-from-chain <program_id> --rpc <url>` variant that fetches the IDL
PDA at init time. Not v1.

## Decision 6: zero impact when no schema is configured

Handlers from Stage 4 keep working unchanged. `event.instruction.decoded`
is always present (never undefined) but `args` is `{}` and `accounts` is
`{}` when no schema applies. Existing handlers reading `event.instruction.data`
and `event.instruction.accounts[i]` are unaffected.

**Why:** existing scenarios (and existing user projects, once published)
should not need to change to compile.

**Revisit if:** the always-present `decoded: { args: {}, accounts: {} }`
becomes confusing in IDE autocomplete. We could narrow per-instruction
codegen so untyped programs get `decoded: undefined`.
