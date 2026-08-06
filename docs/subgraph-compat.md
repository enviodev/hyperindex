# Subgraph compatibility layer — API surface & design

Goal: run `envio dev` / `envio start` inside an unmodified subgraph project
(`subgraph.yaml` + `schema.graphql` + AssemblyScript mappings + `abis/`) with
HyperIndex as the engine. No changes to user source. The served GraphQL API
(Hasura dialect vs graph-node dialect) is explicitly out of scope.

Baseline facts about HyperIndex this design builds on (repo @ `main`):

- The user API is a single `indexer` object: `indexer.onEvent`,
  `indexer.onBlock`, `indexer.contractRegister` (`packages/envio/index.d.ts`).
- Handlers are plain Node ESM loaded through `tsx` at runtime
  (`packages/envio/src/HandlerLoader.res`) — no codegen'd handler package.
- Every handler runs twice per batch: a concurrent **preload** pass
  (`context.isPreload === true`, writes are no-ops, errors swallowed — both
  sync throws and rejections, `EventProcessing.res:200-207`) and a sequential
  **execute** pass.
- `context.<Entity>.get` is async, but the load layer already has synchronous
  in-memory primitives: `hasInMemory`/`getUnsafeInMemory` per load group
  (`LoadManager.res`), sync `set` into `InMemoryTable`, and "known absent"
  recorded after loads (`InMemoryTable.Entity.initValue` stores a `Delete`
  change for missing ids). This is what the sync bridge (§7) builds on.
- Schema parser (`packages/cli/src/config_parsing/entity_parsing.rs`) silently
  ignores unknown entity-level directives (so `@entity(immutable: true)` passes
  through), but hard-rejects `id: Bytes!`, `Int8`, interfaces used as field
  types, and bare entity lists without `@derivedFrom`.
- No existing subgraph/AssemblyScript/WASM/IPFS tooling anywhere in the repo.

## 1. Version matrix

### specVersion (subgraph.yaml)

| specVersion | Added | Shim relevance |
|---|---|---|
| 0.0.4 | `features` declarations (`nonFatalErrors`, `fullTextSearch`, `grafting`) | parse; `nonFatalErrors`/`graft` → unsupported error (§8) |
| 0.0.5 | `receipt: true` on event handlers (needs apiVersion ≥ 0.0.7) | scalars via `field_selection`; `.logs` → unsupported error |
| 0.0.6 | fast PoI calculation | indexer-internal, no-op |
| 0.0.7 | file data sources (`kind: file/ipfs`, `file/arweave`) | emulate via effects |
| 0.0.8 | block handler `polling` / `once` filters | `onBlock` |
| 0.0.9 | `source.endBlock` | `end_block` |
| 1.0.0 | `indexerHints.prune` | no-op (default history pruning ≈ `auto`) |
| 1.1.0 | timeseries & aggregations, `Int8`, `Timestamp` | reject/desugar |
| 1.2.0 | topic filters (`topic1..3`), declared `eth_calls` | `where`, effect pre-warm |
| 1.3.0 | subgraph composition (subgraph data sources) | unsupported error |

### apiVersion (graph-ts / mappings)

| apiVersion | Added |
|---|---|
| 0.0.5 | modern baseline (AS 0.19.10, `gasUsed`→`gasLimit` rename) |
| 0.0.6 | `transaction.nonce`, `block.baseFeePerGas` |
| 0.0.7 | `TransactionReceipt`/`Log` classes, `event.receipt` |
| 0.0.8 | schema-field validation on `save()` |
| 0.0.9 | `ethereum.getBalance`, `ethereum.hasCode` |

Target apiVersion ≥ 0.0.5; anything older is legacy AssemblyScript not worth
supporting.

## 2. Manifest features → HyperIndex

| Feature | Since | Subgraph shape | HyperIndex mapping | Status |
|---|---|---|---|---|
| Contract data source | base | `dataSources[].source: {address, abi, startBlock}` | `contracts` + `chains[].contracts[]`, `start_block` | ✅ |
| `network` name | base | `network: mainnet` | `chains[].id` via static name→id table | ✅ |
| `endBlock` | 0.0.9 | `source.endBlock` | `end_block` | ✅ |
| ABIs | base | `mapping.abis[].file` | `abi_file_path`; also provides param names for the human-readable event signature (subgraph sigs are nameless: `Transfer(indexed address,indexed address,uint256)`) | ✅ |
| Event handlers | base | `eventHandlers[]: {event, handler}` | `events[].event` human sig + generated `indexer.onEvent` wrapper invoking the mapping fn | ✅ |
| `receipt: true` | 0.0.5 | `event.receipt` in mapping | `field_selection.transaction_fields` covers receipt scalars (`status`, `gasUsed`, `cumulativeGasUsed`, `logsBloom`, `contractAddress`); accessing `receipt.logs` throws the unsupported-feature error at runtime | ⚠️ partial |
| Topic filters | 1.2.0 | `topic1: [...]` on event handler | `where: { params: ... }` (arrays = OR) | ✅ |
| Call handlers | base | `callHandlers[]: {function, handler}` | none — no trace/call handler API | ❌ unsupported error |
| Block handler, unfiltered | base | `blockHandlers[]: {handler}` | `indexer.onBlock` with `_every: 1` | ✅ |
| Block handler `filter: call` | base | fires only for blocks containing calls to the contract | none (traces) | ❌ unsupported error |
| Block handler `polling` | 0.0.8 | `filter: {kind: polling, every: N}` | `onBlock` `where: { block: { number: { _every: N } } }` | ✅ |
| Block handler `once` | 0.0.8 | `filter: {kind: once}` | `onBlock` with `_gte: startBlock, _lte: startBlock` | ✅ |
| Templates | base | `templates[]` + `DataSourceTemplate.create(addr)` in mapping | contract with no `address` + `contractRegister`; `create()` calls captured in a register pass (§6) | ✅ w/ design |
| File data sources | 0.0.7 | `kind: file/ipfs` + handler over file content | `createEffect(cache: true)` fetching a gateway; consistency semantics differ (graph isolates FDS entities) | ⚠️ emulated |
| Declared `eth_calls` | 1.2.0 | `calls:` block, pre-fetched in parallel | effects already dedupe/batch; pre-warm in preload | ✅ (optimization) |
| `graft` | 0.0.4 | `graft: {base, block}` | none | ❌ unsupported error |
| `nonFatalErrors` | 0.0.4 | keep indexing past deterministic errors | envio halts on handler error | ❌ unsupported error |
| `fullTextSearch` | 0.0.4 | `_Schema_ @fulltext` | query-layer; out of scope | — strip |
| `indexerHints.prune` | 1.0.0 | history retention hint | default behavior already ≈ `auto` (`max_reorg_depth`, `save_full_history: false`) | ✅ no-op |
| Subgraph composition | 1.3.0 | `kind: subgraph` data sources, `entityHandlers` | none | ❌ unsupported error |

## 3. Schema features → HyperIndex

| Feature | Subgraph shape | HyperIndex mapping | Status |
|---|---|---|---|
| `@entity` | required on every type | silently ignored by parser — passes through as-is | ✅ free |
| `@entity(immutable: true)` | perf hint | ignored (envio has no equivalent; harmless) | ✅ no-op |
| `id: ID!` / `id: String!` | | native | ✅ |
| `id: Bytes!` | the dominant modern style | **hard-rejected** (`id` must be `ID`/`String`/`Int`/`BigInt`) → shim rewrites to `String`, values lowercased 0x-hex at the boundary | ⚠️ transform |
| `Bytes` fields | | `Bytes` → text (hex string) — exists natively | ✅ |
| `BigInt`, `BigDecimal` | AS classes | `bigint` / bignumber.js, `numeric(76[,32])` in pg | ✅ (wrapped in graph-ts classes at the boundary) |
| `Int`, `Float`, `Boolean`, `String` | | native | ✅ |
| `Timestamp` | 1.1.0 (timeseries) | envio `Timestamp` (Date/pg timestamp) | ✅ |
| `Int8` | 1.1.0 | **does not exist** → rewrite to `BigInt` | ⚠️ transform |
| Enums | | native (string-literal unions) | ✅ |
| `@derivedFrom` | virtual reverse relation | identical semantics incl. field-name arg; virtual in handlers both sides | ✅ |
| Derived field loaders | `entity.things.load()` | `context.<E>.getWhere({ fk: { _eq } })` | ✅ (via sync bridge) |
| Stored entity references | `pool: Pool!` | same; handler field is `pool_id` — shim maps the property name | ✅ |
| Stored entity lists | `[Pool!]!` without `@derivedFrom` | rejected → rewrite to `[String!]!` id array, translate in entity class | ⚠️ transform |
| Interfaces | `interface Token { ... }` | dropped by parser; a field typed as an interface then errors → flatten to concrete types or reject | ❌ v1 |
| `_Schema_ @fulltext` | | becomes a broken entity (`no id field`) → strip in shim | — strip |
| Timeseries/`@aggregation` | 1.1.0 | none → reject in v1 (desugar to `onBlock` aggregation later) | ❌ v1 |

## 4. graph-ts mappings API → HyperIndex

| API | apiVersion | HyperIndex mapping | Status |
|---|---|---|---|
| `new Entity(id)` / props / `.save()` | base | `context.<E>.set` via ambient scope (§6) — sync both sides | ✅ |
| `Entity.load(id)` / `store.get` | base | sync try-read from in-memory state; miss → schedule load + suspend (§7) | ✅ |
| `Entity.loadInBlock` / `store.getInBlock` | 0.0.7-era | in-memory-only sync read (no scheduling on miss — miss means "not touched in this block" → `null`) | ✅ |
| `store.remove` | base | `context.<E>.deleteUnsafe(id)` | ✅ |
| `BigInt`/`BigDecimal`/`Bytes`/`Address`/`ByteArray`/`TypedMap` | base | pure-JS shim classes over `bigint`/bignumber.js; converted at every host boundary | ✅ |
| `event.params` | base | `event.params` (envio decodes `uint` → `bigint`, `address` → hex string) wrapped into graph-ts values | ✅ |
| `event.address`, `event.logIndex`, `event.block`, `event.transaction` | base | `srcAddress`, `logIndex`, `block`/`transaction` via `field_selection` (union of fields the mappings touch, or a fixed superset); `transactionLogIndex` unavailable | ✅ mostly |
| `event.receipt` | 0.0.7 | scalar fields work; `.logs` getter throws unsupported-feature error | ⚠️ |
| `Contract.bind(addr).foo()` / `.try_foo()` (sync eth_call) | base | `createEffect` + viem (`envio` ships viem), `cache: true`; sync try-read of effect output, miss → suspend. `try_` wrappers must **re-throw** the suspend error and only convert real failures to `{reverted: true}` | ✅ |
| `ethereum.decode` / `encode` | base | viem `decodeAbiParameters`/`encodeAbiParameters`, sync & pure | ✅ |
| `ethereum.getBalance` / `hasCode` | 0.0.9 | effect via viem; suspend bridge | ✅ |
| `crypto.keccak256` | base | pure JS keccak | ✅ |
| `json.fromBytes` / `try_*` | base | JS `JSON.parse` wrapped in AS `JSONValue` shim | ✅ |
| `log.debug/info/warning/error` | base | `context.log.*`, buffered per replay round and flushed on success (§7) | ✅ |
| `log.critical` | base | throw → halts indexing (same as graph-node) | ✅ |
| `dataSource.create/createWithContext` | base | captured during register pass, routed to `context.chain.<Name>.add` (§6) | ✅ w/ design |
| `dataSource.address()` / `network()` | base | ambient scope; chain id → network name reverse lookup | ✅ |
| `dataSource.context()` | base | graph-node persists per-instance context → shim persists it in an internal entity table | ⚠️ needs persistence |
| `ipfs.cat` / `ipfs.map` | base | effect + IPFS gateway, `cache: true`; suspend bridge | ⚠️ emulated |
| `ens.nameByHash` | — | graph-node uses a local rainbow-table DB → no equivalent; optional effect against a public resolver | ❌/⚠️ |
| `arweave.transactionData` | 0.0.7-era | effect + gateway | ⚠️ emulated |

## 5. Execution-semantics differences

| Concern | graph-node | HyperIndex | Resolution |
|---|---|---|---|
| Handler execution | sync, sequential, deterministic WASM | async, runs twice (preload + execute) | mappings are deterministic by graph-node's own rules, so the double run is safe; the wrapper runs the same replay loop (§7) in both passes — preload warms every read, execute replays zero times in the common case |
| Dynamic source timing | new source reprocesses its creation block | same-block coverage incl. earlier txs (superset) | acceptable |
| Ordering | single network per subgraph, block/log order | same within a chain | non-issue |
| Errors | deterministic error fails subgraph (unless nonFatalErrors) | handler error halts | same behavior; `nonFatalErrors` → unsupported error |
| Reorgs | store rollback | entity-history rollback (`rollback_on_reorg`, default on) | equivalent |

## 6. Entity-write context: AsyncLocalStorage

graph-ts entity ops are ambient (`entity.save()` has no context argument);
envio's are context-scoped. Bridge with an `AsyncLocalStorage<MappingScope>`
holding `{ context, event, mode }`, entered by every generated wrapper. The
shimmed entity classes' `save()` reads `scope.getStore()` and calls
`context[typename].set(...)` — both sides synchronous. The same scope serves
`dataSource.address()` / `network()`.

`dataSource.create(addr)` must land in envio's `contractRegister`, which runs
at fetch time — before the batch pipeline — so the fetcher can track the new
address. For every event whose mapping can create a template instance, the
shim also registers a `contractRegister` wrapper that runs the *same* mapping
in `mode: "register"`. In that mode:

- `dataSource.create` calls are captured and forwarded to
  `context.chain.<Name>.add(addr)` (deduped by address, so replays are
  idempotent);
- store writes and logs are no-ops;
- store **reads return `null`** — `ContractRegisterContext` exposes only
  `log` and `chain.<Name>.add`, entity state does not exist yet at fetch time.
  A `create()` call whose *condition* depends on loaded entity state can
  therefore mis-register; this is a documented caveat (rare in practice —
  factory mappings derive the address from event params);
- eth_calls/effects reached before `create()` → unsupported-feature error
  (no effect API in the register context).

This relies on mappings being deterministic, which graph-node already
requires.

## 7. The sync bridge: try-sync + suspend + replay

`Entity.load`, `try_foo()` eth_calls, `getWhere`, and `ipfs.cat` are
synchronous in AssemblyScript but async in the envio host. Instead of worker
threads or code transforms, the shim uses abort-and-replay:

1. **Try sync.** Each host op first consults the in-memory state
   synchronously. The primitives already exist per load group:
   `hasInMemory`/`getUnsafeInMemory` (`LoadManager.res`), backed by
   `InMemoryTable.Entity.getUnsafe` / `latestEntityChangeById` for entities,
   `hasEffectOutput`/`getEffectOutputUnsafe` for effects (populated even for
   `cache: false` effects — outputs are always kept in memory), and
   `hasIndex`/`getUnsafeOnIndex` for `getWhere` filters. Missing entities are
   a sync hit too: after a load, `InMemoryTable.Entity.initValue` records a
   `Delete` change for absent ids, so "known not to exist" returns `null`
   without re-fetching.
2. **Miss → schedule + suspend.** On a miss, the shim fires the normal async
   op (`LoadLayer.loadById` / `loadEffect` / `loadByFilter` — batched and
   deduped by input key through `LoadManager`, so a replay reuses the same
   in-flight promise) and throws an envio-owned suspend error carrying the
   promise. User code cannot swallow it: AssemblyScript has no
   `try`/`catch`, so no compiled-from-AS mapping contains one. Shim-internal
   `try` blocks (e.g. `try_foo()` revert handling) must re-throw suspend
   errors.
3. **Await + rerun.** The generated wrapper catches the suspend error, awaits
   the round's scheduled promises (`allSettled`; a real load/effect failure is
   re-thrown as the handler error), and re-invokes the mapping from the top.
   Resolved values are now sync hits, so each round makes progress; rounds =
   depth of the mapping's *sequential* dependency chain. The wrapper also
   memoizes resolved values in its scope as a guard against in-memory
   eviction between rounds.

```ts
async function invokeMapping(mapping, gtEvent, context, mode) {
  for (;;) {
    const round = { context, mode, pending: [], logs: [] };
    try {
      scope.run(round, () => mapping(gtEvent));
      round.logs.forEach(flush);
      return;
    } catch (e) {
      if (!isSuspend(e)) throw e;
      await settleOrThrow(round.pending);
    }
  }
}
```

Interaction with envio's two passes makes this cheap:

- **Preload pass** runs all wrappers concurrently with `shouldGroup: true`,
  so first-round misses across the whole batch collapse into batched DB/RPC
  round-trips; suspend throws in preload are already silently swallowed by
  the engine, and the wrapper's own loop drives warmup to completion anyway.
- **Execute pass** then finds everything in memory — the mapping runs start
  to finish synchronously with zero replays in the common case. Writes go
  through sync `InMemoryTable.Entity.set`, so read-own-writes within a round
  is consistent. Replayed writes/`create` calls are idempotent because
  mappings are deterministic; logs are buffered per round and flushed only on
  the successful round, so aborted rounds never emit duplicates.

Small additions needed in envio core (the shim can't reach the in-memory
tables from outside):

- an exported suspend error (identifiable class/symbol, carries the promise);
- sync context ops next to the async ones in `UserContext.res` traps:
  `getSync` (entity), `getWhereSync`, and a sync effect caller — each
  implemented as `hasInMemory ? getUnsafeInMemory : (schedule; throw
  Suspend(promise))`. The effect cache key is already computed synchronously
  (`S.reverseConvertOrThrow` + hash), so the same pattern applies.

A replay-round cap (generous, e.g. 10k) turns a non-deterministic mapping —
one that suspends forever on new keys — into a clear error instead of a hang.

## 8. Unsupported-feature errors

Anything we deliberately don't support fails loudly with one uniform error,
never a silent no-op. Template:

```
Envio Subgraph doesn't support <feature> yet.
  Found in <location, e.g. data source "Token" → callHandlers → "handleApprove">.
First, make sure you're on the latest envio version — support may have landed:
  pnpm add -D envio@latest
If you're up to date and need this feature, please open an issue (existing
issues welcome a 👍 — demand drives prioritization):
  https://github.com/enviodev/hyperindex/issues
```

One factory (`unsupported(feature, location)`) owns the wording; translation
failures list *all* unsupported features found in the project at once, not
just the first.

Final list of features that fail this way:

| Feature | Detected |
|---|---|
| `callHandlers` | translation time (manifest) |
| `blockHandlers` with `filter: call` | translation time (manifest) |
| `graft` | translation time (manifest) |
| `features: [nonFatalErrors]` | translation time (manifest) |
| Subgraph composition (`kind: subgraph` data sources / `entityHandlers`) | translation time (manifest) |
| `event.receipt.logs` | runtime, on property access (receipt scalars keep working) |

## 9. CLI flow

`envio dev` / `envio start`: if no `config.yaml` but a `subgraph.yaml` exists →
subgraph mode:

1. Parse manifest + templates; fail fast with §8 errors (all at once); map
   network names → chain ids; synthesize the envio config under `.envio/`
   (config is generated, so `deny_unknown_fields` is a non-issue). Event
   signatures get param names from the referenced ABI files. `receipt: true`
   and mapping field usage drive `field_selection`.
2. Transform `schema.graphql`: strip `@fulltext`/`_Schema_`, rewrite
   `Bytes` ids → `String`, `Int8` → `BigInt`, stored entity lists → id arrays;
   reject interfaces/aggregations with a clear error.
3. Generate wrapper handler modules (`onEvent`/`onBlock`/`contractRegister`
   per manifest handler) and shim `generated/` modules; a Node resolve hook
   shadows the project's own `generated/` output and `@graphprotocol/graph-ts`.
4. Run the normal dev loop (Postgres + Hasura + indexer). `graph codegen` /
   `graph build` are never needed.

## 10. Phasing

- **P0** (covers the long tail of real subgraphs): sync bridge (§7) + core
  suspend API, event handlers, entity CRUD, `@derivedFrom`, enums, Bytes-id
  rewrite, templates + `dataSource.create`, bound-contract eth_calls, block
  handlers (polling/once), topic filters, `endBlock`, `ipfs.cat` via effect,
  §8 error machinery.
- **P1**: receipts (scalar fields), file data sources, declared-calls
  pre-warm, persisted `dataSource.context()`, interface flattening,
  timeseries desugaring.
- **Unsupported (uniform §8 error)**: `callHandlers`, block `filter: call`,
  `graft`, `nonFatalErrors`, subgraph composition, `event.receipt.logs`.
