open Vitest

// https://github.com/enviodev/hyperindex/issues/1862
// A process of a split run resumes only the chains it drives. Its supervisor
// adds every worker's effect cache counts up, as each chain's cache belongs to
// one worker alone: a worker that read its sibling's would have the sibling's
// rows counted twice.

let chainYaml = chainId =>
  `
  - id: ${chainId->Int.toString}
    rpc:
      url: https://rpc${chainId->Int.toString}.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Token
        address: "0x0000000000000000000000000000000000000001"`

let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: isolated-resume-scope
disable_default_cross_chain: true
contracts:
  - name: Token
    events:
      - event: Transfer(uint256 count)
chains:${chainYaml(1)}${chainYaml(137)}
`,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
  ~handlers=`
import { indexer, createEffect, S } from "envio";

const lookup = createEffect(
  { name: "lookup", input: S.string, output: S.string, rateLimit: false, cache: true },
  async ({ input }) => input
);

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  await context.effect(lookup, event.params.count.toString());
  context.Counter.set({ id: "total", count: event.params.count });
});
`,
)

// Every worker reads a cross-chain cache's rows when it starts: the supervisor
// counts them once, and adds each worker's own writes on top.
let crossChainScenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: isolated-resume-cross-chain-cache
disable_default_cross_chain: true
contracts:
  - name: Token
    events:
      - event: Transfer(uint256 count)
chains:${chainYaml(1)}${chainYaml(137)}
`,
  ~schema=`
type Counter {
  id: ID!
  count: BigInt!
}
`,
  ~handlers=`
import { indexer, createEffect, S } from "envio";

const shared = createEffect(
  { name: "shared", input: S.string, output: S.string, rateLimit: false, cache: true, crossChain: true },
  async ({ input }) => input
);

indexer.onEvent({ contract: "Token", event: "Transfer" }, async ({ event, context }) => {
  await context.effect(shared, event.params.count.toString());
  context.Counter.set({ id: "total", count: event.params.count });
});
`,
)

external toUnknown: bigint => unknown = "%identity"

let transfer = (~block, ~count: bigint): MockSource.itemMock => {
  event: "Token.Transfer",
  blockNumber: block,
  logIndex: 0,
  params: dict{"count": count->toUnknown},
}

describe("A process resuming part of a split run", () => {
  scenario->Scenario.it(
    "reports the effect caches of its own chains only",
    ~sources=[{chain: 1}, {chain: 137}],
    async (~t, ~indexer, ~source) => {
      let (source1, source137) = (source(1), source(137))
      let _ = await Promise.all2((
        Scenario.resolveInitialHeight(~source=source1, ~head=100),
        Scenario.resolveInitialHeight(~source=source137, ~head=100),
      ))
      let _ = await Promise.all2((
        source1.expectItemsQueries([
          {
            fromBlock: 1,
            reply: Respond({items: [transfer(~block=5, ~count=1n)], latestFetchedBlockNumber: 100}),
          },
        ]),
        source137.expectItemsQueries([
          {
            fromBlock: 1,
            reply: Respond({
              items: [transfer(~block=5, ~count=2n), transfer(~block=6, ~count=3n)],
              latestFetchedBlockNumber: 100,
            }),
          },
        ]),
      ))
      await indexer.waitUntilIdle()

      let worker = await indexer.restart(~chains=[ChainId.fromInt(1)], ())

      t.expect(await worker.metric("envio_effect_cache")).toEqual([
        {value: "1", labels: dict{"effect": "lookup", "scope": "1"}},
      ])
    },
  )

  crossChainScenario->Scenario.it(
    "has its supervisor count a cross-chain cache's stored rows once",
    ~sources=[{chain: 1}, {chain: 137}],
    async (~t, ~indexer, ~source) => {
      let (source1, source137) = (source(1), source(137))
      let _ = await Promise.all2((
        Scenario.resolveInitialHeight(~source=source1, ~head=100),
        Scenario.resolveInitialHeight(~source=source137, ~head=100),
      ))
      let _ = await Promise.all2((
        source1.expectItemsQueries([
          {
            fromBlock: 1,
            reply: Respond({items: [transfer(~block=5, ~count=1n)], latestFetchedBlockNumber: 100}),
          },
        ]),
        source137.expectItemsQueries([
          {
            fromBlock: 1,
            reply: Respond({
              items: [transfer(~block=5, ~count=2n), transfer(~block=6, ~count=3n)],
              latestFetchedBlockNumber: 100,
            }),
          },
        ]),
      ))
      await indexer.waitUntilIdle()

      let worker1 = await indexer.restart(~chains=[ChainId.fromInt(1)], ())
      let snapshot1 = worker1.snapshot()
      let worker137 = await worker1.restart(~chains=[ChainId.fromInt(137)], ())
      let merged = Metrics.merge(
        [snapshot1, worker137.snapshot()],
        ~startTime=Date.make(),
        ~metricTime=Date.make(),
        ~elapsedSeconds=0.,
        ~targetBufferSize=0,
      )

      t.expect(
        merged.effects->Array.map(effect => (effect.effect, effect.scope, effect.cacheCount)),
      ).toEqual([("shared", "crossChain", Some(3))])
    },
  )
})
