# Envio Subgraph: API surface & design

**Goal:** `envio dev` / `envio start` work inside an unmodified subgraph
project (`subgraph.yaml` + `schema.graphql` + AssemblyScript mappings +
`abis/`), with HyperIndex underneath. Query-API differences (Hasura vs
graph-node GraphQL) are out of scope.

**How it works, in one paragraph.** The CLI detects `subgraph.yaml`,
translates the manifest into an envio config and the schema into an envio
schema, and points the handler entry at a runtime that imports the user's
mappings unchanged (AssemblyScript is a TypeScript subset — envio already
loads TS via `tsx`). Only `@graphprotocol/graph-ts` is shimmed at runtime;
the project's `generated/` code — `graph codegen` output — executes as-is on
top of the shim (§6a). Each manifest handler becomes an `indexer.onEvent` /
`onBlock` / `contractRegister` wrapper that runs the mapping synchronously;
ambient APIs (`entity.save()`, `dataSource.address()`) find their envio
context through AsyncLocalStorage; async host ops (`Entity.load`, eth_calls,
`ipfs.cat`) are bridged by suspend-and-replay (§5). Anything unsupported
fails with one uniform, loud error (§7) — never a silent no-op.

## 1. Version matrix

specVersion (manifest): **0.0.4** feature declarations · **0.0.5**
`receipt: true` · **0.0.6** fast PoI (no-op) · **0.0.7** file data sources ·
**0.0.8** polling/once block handlers · **0.0.9** `endBlock` · **1.0.0**
`indexerHints.prune` · **1.1.0** timeseries/aggregations, `Int8`, `Timestamp`
· **1.2.0** topic filters, declared eth_calls · **1.3.0** subgraph
composition.

apiVersion (graph-ts): **0.0.5** modern baseline · **0.0.6** `tx.nonce`,
`block.baseFeePerGas` · **0.0.7** `event.receipt` · **0.0.8** field
validation on `save()` · **0.0.9** `getBalance`/`hasCode`. Support ≥ 0.0.5.

## 2. Manifest → envio config

| Feature | Mapping | Status |
|---|---|---|
| Data source (`address`, `abi`, `startBlock`, `endBlock`) | `contracts` + `chains[].contracts`, `start_block`/`end_block` | ✅ |
| `network: mainnet` | `chains[].id` via name→id table | ✅ |
| Event handlers (nameless sigs: `Transfer(indexed address,...)`) | human-readable sig with param names pulled from the ABI file + `onEvent` wrapper | ✅ |
| `receipt: true` | scalars (`status`, `gasUsed`, `cumulativeGasUsed`, `logsBloom`, `contractAddress`) via `field_selection`; `receipt.logs` → §7 error on access | ⚠️ |
| Topic filters (1.2.0) | `where: { params: ... }` (arrays = OR) | ✅ |
| Block handler `polling every: N` / `once` (0.0.8) | `onBlock` `_every: N` / `_gte = _lte = startBlock` | ✅ |
| Block handler, unfiltered | `onBlock` `_every: 1` | ✅ |
| Block handler's `ethereum.Block` arg | envio `onBlock` provides only `block.number` — other fields (`hash`, `timestamp`, …) → §7 error on access | ⚠️ |
| Templates + `dataSource.create()` | address-less contract + `contractRegister` register pass (§4) | ✅ |
| File data sources (0.0.7) | `createEffect(cache: true)` against IPFS/Arweave gateway | ⚠️ emulated |
| Declared `eth_calls` (1.2.0) | effects already batch/dedupe in preload | ✅ |
| `fullTextSearch` / `indexerHints.prune` | strip / no-op (default pruning ≈ `auto`) | — |
| `callHandlers`, block `filter: call`, `graft`, `nonFatalErrors`, composition (1.3.0) | — | ❌ §7 error |

## 3. Schema → envio schema

Passes through unchanged: `@entity` and `@entity(immutable: true)` (envio's
parser ignores unknown entity directives), `String`/`Int`/`Boolean`/`Bytes`/
`BigInt`/`BigDecimal`/`Timestamp`, enums, `@derivedFrom` (identical
semantics), stored entity references.

Rewritten by the translator: `id: Bytes!` → `String` (lowercase 0x-hex at the
boundary; envio only allows `ID`/`String`/`Int`/`BigInt` ids), `Int8` →
`BigInt` (Int8 is a 64-bit integer — `i64` in AS; envio's `Int` is 32-bit
and JS numbers are only safe to 2^53, so `BigInt` is the lossless fit),
stored entity lists → `[String!]!` id arrays, `_Schema_ @fulltext` stripped.

§7 error: **interfaces** (`interface X` / `implements`) and
**timeseries/aggregations** (`@entity(timeseries: true)`, `@aggregation`).

## 4. Mappings (graph-ts) → envio runtime

| API | Mapping |
|---|---|
| `new Entity(id)` → `.save()`, `store.remove` | `context.<E>.set` / `deleteUnsafe` via ALS scope — sync both sides |
| `Entity.load`, `store.get`, derived loaders, `getInBlock` | sync try-read; miss → suspend (§5). `getInBlock` never suspends: miss = `null` |
| `BigInt`/`BigDecimal`/`Bytes`/`Address`/`TypedMap`/`JSONValue` | pure-JS classes over `bigint`/bignumber.js, converted at every host boundary |
| `event.*` | `params`/`srcAddress`/`logIndex` direct; block/tx via `field_selection`; `transactionLogIndex` (log's index within its tx — envio has no per-tx log index) → §7 error on access |
| `Contract.bind(x).foo()` / `.try_foo()` | effect + viem (bundled), `cache: true`, via suspend; `try_` re-throws suspend, only real failures → `{reverted: true}` |
| `ethereum.decode/encode`, `crypto.keccak256`, `json.*` | pure sync JS (viem, keccak) |
| `ethereum.getBalance`/`hasCode` (0.0.9) | effect via viem, suspend |
| `log.*` | `context.log`, buffered per replay round, flushed on success; `log.critical` throws (halts, as graph-node) |
| `dataSource.create/createWithContext` | captured in register pass (below) |
| `dataSource.address()/network()` | ALS scope + chain-id→name reverse lookup |
| `dataSource.context()` | persisted in an internal entity table |
| `ipfs.cat/map`, `arweave.*` | effect + gateway, `cache: true`, suspend |
| `ens.nameByHash` | best-effort effect against public ENS data, `cache: true`; `null` on miss/failure (graph-node also returns `null` when its rainbow table lacks the hash) |

**Register pass.** `dataSource.create` must reach envio's `contractRegister`,
which runs at fetch time — before any entities exist. For each
template-creating event the shim registers a wrapper that reruns the same
mapping in register mode: `create()` → `context.chain.<Name>.add(addr)`
(deduped, so replays are idempotent); writes/logs → no-ops; **reads → `null`**
(no entity state exists at fetch time — a `create()` conditioned on loaded
state can mis-register; documented caveat, rare in practice); effects before
`create()` → §7 error. Safe because graph-node already requires mappings to
be deterministic.

## 5. Sync bridge: try-sync, suspend, replay

graph-ts host ops are synchronous; envio's are async. Bridge:

1. **Try sync.** Read the in-memory state first. The primitives exist:
   `hasInMemory`/`getUnsafeInMemory` per load group (`LoadManager.res`),
   entity tables (`InMemoryTable.Entity.getUnsafe`; absence is recorded after
   loads, so "known missing" is a sync `null`), effect outputs (kept in
   memory even with `cache: false`), `getWhere` indexes.
2. **Miss → schedule + suspend.** Fire the normal async op (batched, deduped
   by input key — replays reuse the in-flight promise), push its promise onto
   the round's pending list, and throw an envio-owned suspend error. User code
   can't swallow it: AssemblyScript has no `try`/`catch`. Shim-internal
   `try` blocks (`try_foo`) re-throw it.
3. **Await + rerun.** The wrapper catches the suspend, `allSettled`s pending
   (real failures re-thrown as the handler error), reruns the mapping from
   the top. Rounds = depth of the sequential load chain; a generous cap
   (~10k) turns non-determinism into a clear error. Resolved values are
   memoized in the scope against in-memory eviction between rounds.

**Abort hardening.** The context's lifecycle collapses into a single status
field on the internal per-event context params, replacing the existing
`isResolved` boolean:

```rescript
type contextStatus = Active | Aborted(exn) | Resolved
```

Suspending sets `Aborted(suspendError)`. While aborted, every context trap
access *and* every op closure (including ones grabbed before the abort)
re-throws the stored suspend error — so even a caught suspend stops the
handler at its next context interaction. `Resolved` keeps today's
"access after the handler resolved" error. The replay loop resets
`Aborted → Active` each round; the engine sets `Resolved` where it sets
`isResolved` today. The status must be shared by reference with entity
sub-proxies (today `entityContextParams` copies `isResolved` by value — this
refactor fixes that).

**Why it's fast:** envio runs handlers twice. The preload pass runs all
wrappers concurrently (`shouldGroup: true`), so first-round misses across the
batch collapse into batched DB/RPC round-trips — and preload already swallows
all handler errors (`EventProcessing.res`), suspends included. The execute
pass then finds everything in memory and runs each mapping start-to-finish
with zero replays in the common case. Writes are sync
(`InMemoryTable.Entity.set`), so read-own-writes holds within a round;
replayed writes are idempotent by determinism.

**Envio-core additions needed** (shims can't reach the in-memory tables).
All of these are **internal-only**: not in `index.d.ts`, not documented,
reserved for the subgraph runtime — free to change between releases since
the runtime ships in the same package (§8).

- an identifiable suspend error;
- sync siblings in `UserContext.res` traps — `getSync`, `getWhereSync`, a
  sync effect caller: `hasInMemory ? getUnsafeInMemory : (schedule; push
  pending; abort; throw)`. Effect cache keys are already computed
  synchronously;
- the replay loop itself as an internal `runSync(context, fn)` so core owns
  round reset (`Aborted → Active`, clear pending) and settle-and-rethrow.
  v1 has no termination guard — mappings are deterministic by graph-node's
  rules, so every round makes progress. Later hardening (if needed): a
  progress check (suspending on an already-resolved key = non-determinism or
  eviction loop → clear error naming the handler and key).

## 6. AsyncLocalStorage scope

One `AsyncLocalStorage<{ context, event, mode, pending, logs }>` entered by
every wrapper. Entity classes, `dataSource.*`, `log.*`, and the suspend
machinery all read it — no context parameter anywhere in user-visible API,
matching graph-ts exactly. Execute is sequential today, but ALS keeps the
design valid under concurrent preload and any future parallelism.

## 6a. Generated code runs as-is (type safety by construction)

Verified against graph-cli's codegen (`graph-tooling`
`packages/cli/src/codegen/{schema,typescript,template}.ts`): everything
`graph codegen` emits is implemented **purely in terms of graph-ts APIs** —
entity classes extend `Entity` (a `TypedMap`), store fields as `Value`s, and
call `store.get`/`store.set`/`store.get_in_block`/`store.loadRelated`;
contract bindings extend `ethereum.SmartContract` and go through
`super.call`/`tryCall`; event classes extend `ethereum.Event`; template
classes call `DataSource.create`. Consequences:

- **No `generated/*` shim.** The real `graph codegen` output is executed
  directly through `tsx`; mappings' relative imports resolve from disk. The
  resolve hook only swaps `@graphprotocol/graph-ts`; the runtime injects the
  few AS builtin globals generated code uses (`changetype` = identity,
  `assert`).
- **Type safety is byte-identical by construction.** Editor and `tsc` see
  the project's own `generated/` files and the *real* `@graphprotocol/graph-ts`
  package types (still in the project's dependencies) — exactly what a
  subgraph developer sees today. Our shim replaces graph-ts at runtime
  resolution only, never at type level.
- **Codegen:** if `generated/` is missing (usually gitignored), `envio dev`
  runs the project's own locally installed graph-cli (resolved from
  `node_modules/.bin/graph`) — output is then identical to the user's normal
  workflow by definition. Both failure modes get explicit messages:

  graph-cli not installed (or `node_modules` missing):

  ```
  Envio Subgraph needs the project's generated code, but "generated/" is
  missing and @graphprotocol/graph-cli isn't installed.
  Install dependencies and try again:
    pnpm install
  Or generate manually:
    pnpm exec graph codegen
  ```

  `graph codegen` exits non-zero (its output shown verbatim above the tail):

  ```
  Envio Subgraph ran `graph codegen` to build "generated/", but it failed —
  the error above comes from The Graph's own codegen, so fix it there and
  rerun. If `graph codegen` succeeds on its own but fails through envio,
  please open an issue: https://github.com/enviodev/hyperindex/issues
  ```
- **Conformance is tested two ways:** (a) golden fixtures — `generated/`
  outputs of real `graph codegen` across pinned graph-cli versions, executed
  against the shim in `envio-tests`, since users' local versions vary; (b) a
  type-level test compiling the shim implementation against the real
  graph-ts type declarations (`satisfies typeof import("@graphprotocol/graph-ts")`)
  so the runtime surface can't drift from the types users compile against.

Cost note: entity field access now goes through `TypedMap`/`Value` boxing —
same data path as graph-node's WASM host, conversion to envio rows happens
only at the `store` boundary. Deny-unknown still holds: unknown members on
generated classes fall through to the shim's `Entity`/`SmartContract` base
prototypes, where the prototype-tail Proxy (§7) throws.

## 6b. Tokens, RPC & extra settings

subgraph.yaml has no place for provider config — graph-node keeps RPC in its
own config, not the project. Three channels, by escalating need; none touch
subgraph.yaml:

Two env vars, nothing else — no envio-side config file. Every other knob
(`hypersync_config.url`, `full_batch_size`, `block_lag`, `max_reorg_depth`,
effect rate limits, IPFS gateway) stays at envio defaults in subgraph mode.

| Need | Channel | Behavior |
|---|---|---|
| HyperSync token | `ENVIO_API_TOKEN` (process env or `.env`, loaded in subgraph mode) | required for the default HyperSync source; missing → setup error at startup |
| RPC for sync fallback + contract calls | `ENVIO_SUBGRAPH_RPC` | optional for sync (HyperSync is primary), required the moment a mapping performs a contract call — HyperRPC doesn't support `eth_call` |

- **`ENVIO_SUBGRAPH_RPC` value = envio's rpc config**, not just a URL:
  `<url>` | `{...}` (JSON object matching the config `rpc` entry schema —
  `url`, `for`, `ws`, `headers`, backoff/interval tuning) | `[<url>|{...}]`
  (JSON array mixing both). Parsed with the same schema and deny-unknown
  rules as config.yaml's `rpc` field, then injected into the generated
  chain config verbatim (bare URLs default to `for: fallback`). The shim's
  call effects (`ethereum.call`/`try_`/`getBalance`/`hasCode`) use the same
  entries in order as a viem fallback transport.
- **Contract calls fail lazily but clearly.** Whether mappings call
  contracts isn't statically knowable, so the first `ethereum.call` without
  `ENVIO_SUBGRAPH_RPC` raises:

  ```
  This subgraph performs contract calls (Token.try_name()), which need an
  RPC endpoint — HyperSync and HyperRPC serve logs and blocks, not eth_call.
  Set one in .env or the environment:
    ENVIO_SUBGRAPH_RPC=https://...
  Advanced (matches envio's rpc config; single entry or array):
    ENVIO_SUBGRAPH_RPC={"url":"https://...","for":"fallback","headers":{...}}
  ```

  A subgraph.yaml says *what* to index; these two vars are the only
  envio-side *how*.

- **Missing token error** points at https://envio.dev/app/api-tokens with
  the `.env` one-liner, same tone as the graph-cli setup error (§6a).
- Translation pins `address_format: lowercase` (not envio's checksum
  default): graph-ts renders addresses lowercase, and id/derived-key parity
  depends on it. Not overridable.

## 7. Unsupported & unknown errors

Two error kinds, one factory each, shared tail. Translation reports **all**
findings at once, not just the first.

**Unsupported** — a feature we recognize and deliberately don't implement:

```
Envio Subgraph doesn't support <feature> yet.
  Found in <location, e.g. data source "Token" → callHandlers → "handleApprove">.
First, make sure you're on the latest envio version — support may have landed:
  pnpm add -D envio@latest
If you're up to date and need this feature, please open an issue (existing
issues welcome a 👍 — demand drives prioritization):
  https://github.com/enviodev/hyperindex/issues
```

**Unknown** — something we don't recognize at all (a newer subgraph feature,
a newer graph-ts API, or a typo). Nothing unknown is ever ignored:

```
Envio Subgraph doesn't know <thing>.
  Found in <location>.
This may be a feature newer than this envio version understands, or a typo.
First, make sure you're on the latest envio version:
  pnpm add -D envio@latest
If you're up to date and this is a real subgraph feature, please open an
issue so we can add it: https://github.com/enviodev/hyperindex/issues
```

**Deny-unknown everywhere.** graph-node ignores what it doesn't expect; we
refuse instead, so behavior never silently diverges:

- *Manifest*: `deny_unknown_fields` on every subgraph.yaml struct; unknown
  `kind`, unknown `features` entries, unknown block-handler filter kinds,
  and `specVersion`/`apiVersion` above the supported range all raise the
  unknown error with the YAML path as location.
- *Schema*: unknown directives, unknown arguments on known directives
  (e.g. `@entity(...)` beyond `immutable`/`timeseries`), and unknown type
  names that aren't schema-defined raise the unknown error.
- *Runtime*: every shim surface is strict, via three mechanisms picked by
  path heat and whether the unknown names are enumerable (precedent:
  `UserContext.res` already Proxy-traps invalid context access):
  1. **Full Proxy** on the graph-ts namespace objects (`store`, `ethereum`,
     `dataSource`, `json`, `crypto`, `ipfs`, `ens`, `arweave`, `log`) —
     future graph-ts APIs are unenumerable, so only a `get` trap can catch
     them; cold path, trap cost is negligible.
  2. **Prototype-tail Proxy** on hot classes (value classes, entities, event
     objects): instance → real prototype with all known members (plain
     properties, V8-optimizable) → base object whose Proxy throws the
     unknown error. Known lookups never reach the trap — zero overhead;
     unknown names fall through the chain and throw.
  3. **Plain throwing getters** for known-but-refused fields
     (`receipt.logs`, `transactionLogIndex`, block fields beyond `number`) —
     enumerable names need no Proxy and throw the *unsupported* error,
     keeping the unsupported/unknown distinction crisp.

  Traps must return `undefined` for symbols and a small allowlist (`then`,
  `toJSON`, `constructor`, `valueOf`, `Symbol.toPrimitive`, inspect) so
  `console.log`/`await`/`JSON.stringify` don't explode; safe because
  AS-compiled mappings never feature-detect. Unknown *named imports* fail at
  Node's ESM link step before any Proxy runs — the registration entry
  catches mapping-module import errors and rewraps the missing-export name
  into the unknown-error template.

| Feature | Detected |
|---|---|
| `callHandlers` | translation (manifest) |
| `blockHandlers` with `filter: call` | translation (manifest) |
| `graft` | translation (manifest) |
| `features: [nonFatalErrors]` | translation (manifest) |
| Subgraph composition (`kind: subgraph`, `entityHandlers`) | translation (manifest) |
| GraphQL interfaces | translation (schema) |
| Timeseries & aggregations | translation (schema) |
| `event.receipt.logs` | runtime, on access (receipt scalars keep working) |
| `event.transactionLogIndex` | runtime, on access |
| Block-handler `ethereum.Block` fields other than `number` | runtime, on access |

## 8. Implementation plan

**A. Envio core** (`packages/envio`) — independent, start here.
1. Suspend error type; replace `isResolved` with the `status` field
   (`Active | Aborted(exn) | Resolved`) on `contextParams`, shared by
   reference with entity sub-proxies; `pending` list per handler invocation.
2. Sync ops: `LoadLayer` sync try-entry-points; `getSync` / `getWhereSync` /
   sync effect caller traps in `UserContext.res`; status check in every op
   closure and trap. Internal-only — kept out of `index.d.ts` and docs.
3. Internal `runSync` replay loop (round reset, allSettled; no termination
   guard in v1).
4. Tests (rung 1, `packages/envio-tests`, `fromUserApi`): sync hit after
   `set`; miss→suspend→replay from DB; known-absent → sync `null`;
   `effectSync` incl. `cache: false`; caught suspend → next access aborts;
   pre-grabbed op closure aborts; round cap.

**B. CLI subgraph mode** (`packages/cli`).
1. `dev`/`start`/`codegen` detect `subgraph.yaml` when `config.yaml` absent.
2. Manifest parser (all specVersions) + §7 error collection; network→chain-id
   table; synthesize `human_config` structs (events with ABI param names,
   `field_selection` from `receipt` + superset default, templates →
   address-less contracts); handler entry → subgraph runtime; embed the
   parsed manifest in the public config JSON under a `subgraph` field
   (extend `publicConfigSchema` in `Config.res`); `.env` loading and
   `ENVIO_SUBGRAPH_RPC` parsing/injection (§6b).
3. Schema transform + §7 schema errors (interfaces, aggregations); write
   transformed schema under `.envio/`.
4. Tests: Rust unit tests over manifest/schema fixtures per specVersion,
   snapshot the multi-error report (unsupported + unknown).

**C. Subgraph runtime + graph-ts shim** — lives inside the `envio` package,
source under `packages/envio/src/subgraph/`, **not exposed at all**: no
subpath export in `package.json`. Nothing outside the package ever imports
it — `HandlerLoader.res` activates it internally when the resolved public
config carries the `subgraph` field, the runtime registers its own resolve
hook for `@graphprotocol/graph-ts`/`generated/*`, user mappings never import
envio, and `envio-tests` reaches internals in-repo. Same-package shipping
also guarantees lock-step versions with the internal core APIs it consumes —
no peer-dep pinning, nothing extra to install in a subgraph project whose
`package.json` doesn't mention envio.
1. Value classes (BigInt, BigDecimal, Bytes, Address, TypedMap, JSONValue),
   `crypto`, `json`, `ethereum.encode/decode` — pure, no envio dependency.
2. Node resolve hook: `@graphprotocol/graph-ts` → the shim (runtime only —
   types keep resolving to the real package); inject AS builtin globals
   (`changetype`, `assert`). The shim implements the full graph-ts surface
   the generated code sits on: `Entity`/`Value`/`TypedMap` + `store` (→ ALS
   scope + `getSync`/`set`/`deleteUnsafe`/`getWhereSync`),
   `ethereum.SmartContract.call/tryCall` (→ effects),
   `DataSourceTemplate.create` (→ register capture), `ethereum.Event` (→
   envio event conversion; `receipt.logs` getter → §7 error). `generated/`
   itself is real `graph codegen` output executed as-is (§6a).
3. Registration entry: read the manifest from the `subgraph` field of the
   resolved public config JSON (`Config.getPublicConfigJson()` — the CLI
   passes the parsed manifest through; no normalized copy in `.envio/`),
   import mappings, register `onEvent`/`onBlock`/`contractRegister` wrappers
   around `runSync`; per-round log buffering.
4. Tests: rung 1 with real mapping sources + golden `generated/` fixtures
   (real `graph codegen` output across pinned graph-cli versions) executed
   through the shim; the `satisfies`-style type conformance check against
   real graph-ts declarations; value-class unit tests against graph-ts
   fixtures. **`SubgraphValidation_test.res`** in
   `packages/envio-tests`, patterned on `UserApiValidation_test.res` (an
   `expectSubgraphError` helper over a `fromSubgraph(~manifest, ~schema,
   ~mappings, ~files)` entry in `InternalTestIndexer`, asserting exact error
   messages): one case per §7 row — every unsupported feature (manifest,
   schema, runtime-access) and every unknown-rejection path (unknown manifest
   field/kind/feature name, too-new specVersion/apiVersion, unknown schema
   directive/argument/type, unknown graph-ts namespace member, unknown
   entity field, unknown event property).

**D. End to end.** `scenarios/subgraph_test`: a real small subgraph project
(e.g. gravatar) with factory + template + eth_call + block handler; run via
`envio dev` path in CI; plus one fixture per §7 error asserting the message.
Additionally, add an **"Envio Subgraph"** tool to
[open-indexer-benchmark](https://github.com/enviodev/open-indexer-benchmark)
that runs the benchmark's existing Subgraph case unmodified on HyperIndex —
serving as both a realistic correctness fixture and a public perf
comparison.

Run after each phase: `cd packages/envio-tests && pnpm rescript && pnpm
vitest run` (A, C), `cargo test -p envio-cli` (B), scenario CI job (D).

**Decisions**
1. Core sync API: internal-only, for the subgraph runtime.
2. Runtime home: inside the `envio` package, fully internal — no subpath
   export (§8 C).
3. `ens.nameByHash`: best-effort cached effect, `null` on miss/failure.
4. Replay termination guard: dropped for the first iteration (determinism
   guarantees progress); progress check is possible later hardening.
