## Plan: Add `simulate` to test indexer `process()` API

### Target API
```ts
await indexer.process({
  chains: {
    1: {
      startBlock: 10_861_674,
      endBlock: 10_861_874,
      simulate: [
        { contract: "ERC20", event: "Transfer", params: { from: "0x...", to: "0x...", value: "1000" } },
        { block: "HandleEvents", number: 10_861_874 },
      ],
    },
  },
})
```

When `simulate` present → skip server fetching, process only user-specified items.

### Steps

#### 1. TS types for simulate items

`packages/envio/index.d.ts` — add `simulate?` to `TestIndexerChainConfig`:
```ts
type SimulateEventItem<Contracts> = {
  [C in keyof Contracts]: {
    [E in keyof Contracts[C]["events"]]: {
      contract: C; event: E;
      params?: Partial<Contracts[C]["events"][E]>;
      srcAddress?: Address; logIndex?: int; number?: number;
      block?: Partial<Block>; transaction?: Partial<Transaction>;
    }
  }[keyof Contracts[C]["events"]]
}[keyof Contracts];

type SimulateBlockItem = { block: string; number?: number };
type SimulateItem<Contracts> = SimulateEventItem<Contracts> | SimulateBlockItem;
```

`packages/cli/src/hbs_templating/codegen_templates.rs` — add `events` map to contract types in `envio.d.ts` codegen (event name → param types).

#### 2. SimulateSource (`packages/envio/src/sources/SimulateSource.res` — NEW)

Implements `Source.t`. Takes pre-built `array<Internal.item>` + `endBlock: int`.
- `getItemsOrThrow`: filter items in `[fromBlock, toBlock]`, return as response
- `getHeightOrThrow`: return `endBlock`
- No network calls

#### 3. Runtime simulate item parsing (`packages/envio/src/TestIndexer.res`)

New function `parseSimulateItems(~simulate: array<Js.Json.t>, ~config, ~startBlock)`:
- Discriminate by `contract`+`event` keys (event) vs `block` key (block handler)
- Event items: look up eventConfig by contract+event name, parse params via `paramsRawEventSchema`, apply defaults (blockNumber from startBlock, logIndex auto-increment per block, srcAddress from contract config, timestamp=0)
- Block items: validate handler name exists in registrations at runtime, apply defaults (number from startBlock, use onBlockConfig.index for ordering)
- Return `array<Internal.item>`

#### 4. Wire into worker flow

- `TestIndexer.initTestWorker`: extract `processConfig` from workerData (already available but unused), pass to `Main.start`
- `Main.start`: accept optional `~processConfig`. After `makeGeneratedConfig()`, for chains with simulate: call `parseSimulateItems`, create `SimulateSource`, override chain's `sourceConfig` to `CustomSources([simulateSource])`
- Rest of pipeline unchanged — `ChainManager.makeFromDbState` picks up `CustomSources`

#### 5. Testing

- `scenarios/test_codegen/test/EventHandler.test.ts`: test simulate events processed correctly with entity changes returned
- Test auto-incrementing logIndex, default block numbers
- Test runtime error for invalid block handler name
- Run `pnpm rescript` + `pnpm vitest run`

### Unresolved questions

1. **Params nested under `params` key or flattened?** Example shows `params: { from, to, value }`. Nested avoids conflicts with `srcAddress`, `logIndex`, `number`, `block`, `transaction`. Flattened is cleaner UX. I lean nested since the example already uses it.
2. **logIndex**: auto-increment per block or globally? Per block seems more realistic.
3. **`startBlock`/`endBlock` optional when simulate present?** Could derive from items. Or keep required for simplicity.
4. **Block timestamp default**: 0 ok for tests?
