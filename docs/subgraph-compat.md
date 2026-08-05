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
  (`context.isPreload === true`, writes are no-ops, errors swallowed) and a
  sequential **execute** pass (`packages/envio/src/EventProcessing.res`).
- `context.<Entity>.get` is **async**; `set`/`deleteUnsafe` are sync.
- Schema parser (`packages/cli/src/config_parsing/entity_parsing.rs`) silently
  ignores unknown entity-level directives (so `@entity(immutable: true)` passes
  through), but hard-rejects `id: Bytes!`, `Int8`, interfaces used as field
  types, and bare entity lists without `@derivedFrom`.
- No existing subgraph/AssemblyScript/WASM/IPFS tooling anywhere in the repo.

## 1. Version matrix

### specVersion (subgraph.yaml)

| specVersion | Added | Shim relevance |
|---|---|---|
| 0.0.4 | `features` declarations (`nonFatalErrors`, `fullTextSearch`, `grafting`) | parse, mostly no-op |
| 0.0.5 | `receipt: true` on event handlers (needs apiVersion ≥ 0.0.7) | partial via `field_selection` |
| 0.0.6 | fast PoI calculation | indexer-internal, no-op |
| 0.0.7 | file data sources (`kind: file/ipfs`, `file/arweave`) | emulate via effects |
| 0.0.8 | block handler `polling` / `once` filters | `onBlock` |
| 0.0.9 | `source.endBlock` | `end_block` |
| 1.0.0 | `indexerHints.prune` | no-op (default history pruning ≈ `prune: auto`) |
| 1.1.0 | timeseries & aggregations, `Int8`, `Timestamp` | reject/desugar |
| 1.2.0 | topic filters (`topic1..3`), declared `eth_calls` | `where`, effect pre-warm |
| 1.3.0 | subgraph composition (subgraph data sources) | out of scope |

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
| Event handlers | base | `eventHandlers[]: {event, handler}` | `events[].event` + generated `indexer.onEvent` wrapper invoking the mapping fn | ✅ |
| `receipt: true` | 0.0.5 | `event.receipt` in mapping | `field_selection.transaction_fields` covers receipt scalars (`status`, `gasUsed`, `cumulativeGasUsed`, `logsBloom`, `contractAddress`); **`receipt.logs` (sibling logs) has no equivalent** | ⚠️ partial |
| Topic filters | 1.2.0 | `topic1: [...]` on event handler | `where: { params: ... }` (arrays = OR) | ✅ |
| Call handlers | base | `callHandlers[]: {function, handler}` | none — no trace/call handler API (`indexer-traces` skill confirms) | ❌ hard error |
| Block handler, unfiltered | base | `blockHandlers[]: {handler}` | `indexer.onBlock` with `_every: 1` | ✅ |
| Block handler `filter: call` | base | fires only for blocks containing calls to the contract | none (traces) | ❌ |
| Block handler `polling` | 0.0.8 | `filter: {kind: polling, every: N}` | `onBlock` `where: { block: { number: { _every: N } } }` | ✅ |
| Block handler `once` | 0.0.8 | `filter: {kind: once}` | `onBlock` with `_gte: startBlock, _lte: startBlock` | ✅ |
| Templates | base | `templates[]` + `DataSourceTemplate.create(addr)` in mapping | contract with no `address` + `contractRegister`; `create()` calls captured in a register pass (§6) | ✅ w/ design |
| File data sources | 0.0.7 | `templates[]: kind: file/ipfs` + handler over file content | `createEffect(cache: true)` fetching a gateway; consistency semantics differ (graph isolates FDS entities) | ⚠️ emulated |
| Declared `eth_calls` | 1.2.0 | `calls:` block, pre-fetched in parallel | effects already dedupe/batch; can pre-warm in preload | ✅ (optimization) |
| `graft` | 0.0.4 | `graft: {base, block}` | none; HyperSync resync is cheap enough to ignore | ❌ warn + full sync |
| `nonFatalErrors` | 0.0.4 | deterministic handler errors don't halt | envio halts on handler error | ❌ no-op |
| `fullTextSearch` | 0.0.4 | `_Schema_ @fulltext` | query-layer; out of scope | — strip |
| `indexerHints.prune` | 1.0.0 | history retention hint | default behavior already ≈ `auto` (`max_reorg_depth`, `save_full_history: false`) | ✅ no-op |
| Subgraph composition | 1.3.0 | `kind: subgraph` data sources, `entityHandlers` | none | ❌ out of scope |

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
| Derived field loaders | `entity.things.load()` | `context.<E>.getWhere({ fk: { _eq } })` | ✅ (needs sync bridge) |
| Stored entity references | `pool: Pool!` | same; handler field is `pool_id` — shim maps property name | ✅ |
| Stored entity lists | `[Pool!]!` without `@derivedFrom` | rejected → rewrite to `[String!]!` id array, translate in entity class | ⚠️ transform |
| Interfaces | `interface Token { ... }` | dropped by parser; a field typed as an interface then errors → flatten to concrete types or reject | ❌ v1 |
| `_Schema_ @fulltext` | | becomes a broken entity (`no id field`) → strip in shim | — strip |
| Timeseries/`@aggregation` | 1.1.0 | none → reject in v1 (desugar to `onBlock` aggregation later) | ❌ v1 |

## 4. graph-ts mappings API → HyperIndex

| API | apiVersion | HyperIndex mapping | Status |
|---|---|---|---|
| `new Entity(id)` / props / `.save()` | base | `context.<E>.set` via ambient scope (§6) — sync both sides | ✅ |
| `Entity.load(id)` / `store.get` | base | `await context.<E>.get(id)` — **sync-over-async bridge required** (§7) | ⚠️ core problem |
| `Entity.loadInBlock` / `store.getInBlock` | 0.0.7-era | in-memory store hit via same bridge | ✅ |
| `store.remove` | base | `context.<E>.deleteUnsafe(id)` | ✅ |
| `BigInt`/`BigDecimal`/`Bytes`/`Address`/`ByteArray`/`TypedMap` | base | pure-JS shim classes over `bigint`/bignumber.js; converted at every host boundary | ✅ |
| `event.params` | base | `event.params` (envio decodes `uint` → `bigint`, `address` → hex string) wrapped into graph-ts values | ✅ |
| `event.address`, `event.logIndex`, `event.block`, `event.transaction` | base | `srcAddress`, `logIndex`, `block`/`transaction` via `field_selection` (select the union of fields the mappings actually touch, or a fixed superset); `transactionLogIndex` unavailable | ✅ mostly |
| `event.receipt` | 0.0.7 | partial — see manifest row | ⚠️ |
| `Contract.bind(addr).foo()` / `.try_foo()` (sync eth_call) | base | `createEffect` + viem (`envio` ships viem), `cache: true`; sync bridge | ✅ w/ bridge |
| `ethereum.decode` / `encode` | base | viem `decodeAbiParameters`/`encodeAbiParameters`, sync & pure | ✅ |
| `ethereum.getBalance` / `hasCode` | 0.0.9 | effect via viem; sync bridge | ✅ w/ bridge |
| `crypto.keccak256` | base | pure JS keccak | ✅ |
| `json.fromBytes` / `try_*` | base | JS `JSON.parse` wrapped in AS `JSONValue` shim | ✅ |
| `log.debug/info/warning/error` | base | `context.log.*` | ✅ |
| `log.critical` | base | throw → halts indexing (same as graph-node) | ✅ |
| `dataSource.create/createWithContext` | base | captured during register pass, routed to `context.chain.<Name>.add` (§6) | ✅ w/ design |
| `dataSource.address()` / `network()` | base | ambient scope; chain id → network name reverse lookup | ✅ |
| `dataSource.context()` | base | graph-node persists per-instance context → shim persists it in an internal entity table | ⚠️ needs persistence |
| `ipfs.cat` / `ipfs.map` | base | effect + IPFS gateway, `cache: true`; sync bridge | ⚠️ emulated |
| `ens.nameByHash` | — | graph-node uses a local rainbow-table DB → no equivalent; optional effect against a public resolver | ❌/⚠️ |
| `arweave.transactionData` | 0.0.7-era | effect + gateway | ⚠️ emulated |

## 5. Execution-semantics differences

| Concern | graph-node | HyperIndex | Resolution |
|---|---|---|---|
| Handler execution | sync, sequential, deterministic WASM | async, **runs twice** (preload + execute) | v1: early-return when `context.isPreload` — correct, forfeits preload perf. Later: deterministic replay-preload. |
| Dynamic source timing | new source reprocesses its creation block | same-block coverage incl. earlier txs (superset) | acceptable |
| Ordering | single network per subgraph, block/log order | same within a chain | non-issue |
| Errors | deterministic error fails subgraph (unless nonFatalErrors) | handler error halts | acceptable |
| Reorgs | store rollback | entity-history rollback (`rollback_on_reorg`, default on) | equivalent |

## 6. Entity-write context: AsyncLocalStorage

graph-ts entity ops are ambient (`entity.save()` has no context argument);
envio's are context-scoped. Bridge with an `AsyncLocalStorage<MappingScope>`
holding `{ context, event, mode }`, entered by every generated wrapper:

```ts
const scope = new AsyncLocalStorage<MappingScope>();

indexer.onEvent({ contract, event }, async ({ event, context }) => {
  if (context.isPreload) return;
  await scope.run({ context, event, mode: "execute" }, () =>
    invokeMapping(handlerFn, toGraphTsEvent(event)));
});

// shimmed generated/schema entity class
save() {
  const { context, mode } = scope.getStore()!;
  if (mode === "register") return;
  context[this.__typename].set(toEnvioRow(this));
}
```

`dataSource.create(addr)` needs to land in a `contractRegister`, which runs in
a separate earlier pass. Solution: for every event whose mapping can create a
template instance, also register a `contractRegister` wrapper that runs the
same mapping in `mode: "register"` — store reads work, writes/logs are no-ops,
and only `dataSource.create` calls are captured and forwarded to
`context.chain.<Name>.add(addr)`. This relies on mappings being deterministic,
which graph-node already requires. Cost: those mappings execute twice, same
order of overhead as envio's own preload model.

Note: with preload skipped, the execute pass is sequential, so a plain
module-level variable would work today — ALS is the future-proof version that
survives concurrent replay-preload.

## 7. The sync-over-async problem

`Entity.load`, `try_foo()` eth_calls, and `ipfs.cat` are synchronous in
AssemblyScript but async in the envio host. Three options:

1. **Worker + Atomics (recommended v1).** Run each mapping invocation in a
   worker thread (source loaded via tsx, imports of `@graphprotocol/graph-ts`
   and `../generated/*` redirected to shims by a resolve hook). Host ops post
   to the parent and block on `Atomics.wait` over a SharedArrayBuffer until the
   parent resolves the envio promise (the `synckit` pattern). Zero source
   changes, no static analysis, works on any mapping. This is structurally what
   graph-node's WASM host does.
2. **Load-time async codemod.** AS is a TS subset; transform at load time:
   make handlers async, insert `await` at known-async call sites, propagate
   async through user helpers transitively. Envio's execute pass awaits each
   handler sequentially, so introduced suspension points are safe. Enables true
   preload/effect batching (big perf win) but a missed await fails silently —
   keep as the perf path behind the worker fallback.
3. **Real WASM host.** Compile mappings with `asc` and implement graph-node's
   host imports + AS memory marshalling in Node. Maximal fidelity (exact i32
   wraparound semantics etc.); large effort; endgame only if TS-execution
   semantic drift bites in practice.

Running AS source as TS is semantically close but not identical: `i32`/`u8`
wraparound and integer division don't exist in JS numbers. In practice
mappings do nearly all math in `BigInt`/`BigDecimal` (shim classes, exact), so
drift is confined to rare raw-integer arithmetic.

## 8. CLI flow

`envio dev` / `envio start`: if no `config.yaml` but a `subgraph.yaml` exists →
subgraph mode:

1. Parse manifest + templates; map network names → chain ids; synthesize the
   envio config under `.envio/` (config is generated, so
   `deny_unknown_fields` is a non-issue). Event signatures get param names from
   the referenced ABI files. `receipt: true` and mapping field usage drive
   `field_selection`.
2. Transform `schema.graphql`: strip `@fulltext`/`_Schema_`, rewrite
   `Bytes` ids → `String`, `Int8` → `BigInt`, stored entity lists → id arrays;
   reject interfaces/aggregations with a clear error.
3. Generate wrapper handler modules (`onEvent`/`onBlock`/`contractRegister`
   per manifest handler) and shim `generated/` modules; a Node resolve hook
   shadows the project's own `generated/` output and `@graphprotocol/graph-ts`.
4. Run the normal dev loop (Postgres + Hasura + indexer). `graph codegen` /
   `graph build` are never needed.

## 9. Phasing

- **P0** (covers the long tail of real subgraphs): event handlers, entity
  CRUD, `@derivedFrom`, enums, Bytes-id rewrite, templates +
  `dataSource.create`, bound-contract eth_calls, block handlers
  (polling/once), topic filters, `endBlock`, `ipfs.cat` via effect.
- **P1**: receipts (scalar fields), file data sources, declared-calls
  pre-warm, persisted `dataSource.context()`, codemod-based preload for
  performance.
- **Rejected loudly at translation time**: `callHandlers`, block `filter:
  call`, grafting, `nonFatalErrors`, timeseries/aggregations, subgraph
  composition, `ens.nameByHash`.
