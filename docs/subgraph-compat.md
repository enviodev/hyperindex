# Envio Subgraph: API surface & design

**Goal:** `envio dev` / `envio start` work inside an unmodified subgraph
project (`subgraph.yaml` + `schema.graphql` + AssemblyScript mappings +
`abis/`), with HyperIndex underneath. Query-API differences (Hasura vs
graph-node GraphQL) are out of scope.

**How it works, in one paragraph.** The CLI detects `subgraph.yaml`,
translates the manifest into an envio config and the schema into an envio
schema, and points the handler entry at a runtime that imports the user's
mappings unchanged (AssemblyScript is a TypeScript subset — envio already
loads TS via `tsx`). Imports of `@graphprotocol/graph-ts` and `generated/*`
resolve to shims. Each manifest handler becomes an `indexer.onEvent` /
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
- *Runtime*: every shim surface is a strict object — `@graphprotocol/graph-ts`
  namespaces (`store`, `ethereum`, `dataSource`, `json`, `crypto`, `ipfs`,
  `ens`, `arweave`, `log`), generated entity/contract classes, and event
  objects are wrapped so accessing or importing anything unimplemented
  throws the unknown error naming the symbol (e.g.
  `graph-ts → ethereum.someNewApi`) instead of returning `undefined`.

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
   (extend `publicConfigSchema` in `Config.res`).
3. Schema transform + §7 schema errors (interfaces, aggregations); write
   transformed schema under `.envio/`.
4. Tests: Rust unit tests over manifest/schema fixtures per specVersion,
   snapshot the multi-error report (unsupported + unknown).

**C. Subgraph runtime + graph-ts shim** — lives inside the `envio` package
as an undocumented subpath export (`envio/subgraph`), source under
`packages/envio/src/subgraph/`. Rationale: it consumes internal-only core
APIs (decision above), so shipping in the same package guarantees lock-step
versions — no peer-dep pinning, no version-skew errors, and nothing extra to
install in a subgraph project that has no envio in its `package.json` to
begin with. Split into its own package later only if the graph-ts value
classes prove useful standalone.
1. Value classes (BigInt, BigDecimal, Bytes, Address, TypedMap, JSONValue),
   `crypto`, `json`, `ethereum.encode/decode` — pure, no envio dependency.
2. Node resolve hook: `@graphprotocol/graph-ts` + `generated/*` → shims built
   at load time from transformed schema + ABIs (entity classes → ALS +
   `getSync`/`set`; contract bindings → effects; template classes → register
   capture; `event.receipt.logs` getter → §7 error).
3. Registration entry: read the manifest from the `subgraph` field of the
   resolved public config JSON (`Config.getPublicConfigJson()` — the CLI
   passes the parsed manifest through; no normalized copy in `.envio/`),
   import mappings, register `onEvent`/`onBlock`/`contractRegister` wrappers
   around `runSync`; per-round log buffering.
4. Tests: rung 1 with real mapping sources through the shim; value-class unit
   tests against graph-ts fixtures. **`SubgraphValidation_test.res`** in
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
2. Runtime home: `envio/subgraph` subpath inside the `envio` package (§8 C).
3. `ens.nameByHash`: best-effort cached effect, `null` on miss/failure.
4. Replay termination guard: dropped for the first iteration (determinism
   guarantees progress); progress check is possible later hardening.
