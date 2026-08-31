open Vitest

let makeChain = (~startBlock, ~endBlock=?, ~source): Config.chain => {
  name: "Chain1",
  id: 1->ChainId.fromInt,
  ecosystem: Ecosystem.Evm,
  startBlock,
  ?endBlock,
  maxReorgDepth: 10,
  blockLag: 0,
  contracts: [],
  sourceConfig: Config.CustomSources([source]),
}

describe("StartBlockResolver", () => {
  Async.it(
    "passes an already-resolved Number through unchanged, without touching the source",
    async t => {
      let mockSource = MockSource.make([], ~chainId=1)
      let chain = makeChain(~startBlock=Config.Number(42), ~source=mockSource.source)

      let resolved = await [chain]->StartBlockResolver.resolveAllOrThrow(~lowercaseAddresses=false)

      t.expect((
        resolved->Array.map(c => c.startBlock),
        mockSource.getHeightOrThrowCalls->Array.length,
      )).toEqual(([Config.Number(42)], 0))
    },
  )

  Async.it("resolves Latest to the source's current height", async t => {
    let mockSource = MockSource.make([#getHeightOrThrow], ~chainId=1, ~autoHeight=12345)
    let chain = makeChain(~startBlock=Config.Latest, ~source=mockSource.source)

    let resolved = await [chain]->StartBlockResolver.resolveAllOrThrow(~lowercaseAddresses=false)

    t.expect((
      resolved->Array.map(c => c.startBlock),
      mockSource.getHeightOrThrowCalls->Array.length,
    )).toEqual(([Config.Number(12345)], 1))
  })

  Async.it(
    "throws a clear error when the resolved latest start block is past end_block",
    async t => {
      let mockSource = MockSource.make([#getHeightOrThrow], ~chainId=1, ~autoHeight=100)
      let chain = makeChain(~startBlock=Config.Latest, ~endBlock=50, ~source=mockSource.source)

      let error = try {
        let _ = await [chain]->StartBlockResolver.resolveAllOrThrow(~lowercaseAddresses=false)
        None
      } catch {
      | JsExn(e) => e->JsExn.message
      }

      t.expect(error).toEqual(
        Some(`Chain 1: the resolved "latest" start block (100) is greater than the configured end_block (50). There is nothing to index - remove end_block, raise it above the chain's current head, or pin start_block to a fixed value instead of "latest".`),
      )
    },
  )

  Async.it("retries with backoff until the source stops rejecting", async t => {
    let mockSource = MockSource.make([#getHeightOrThrow], ~chainId=1)
    let chain = makeChain(~startBlock=Config.Latest, ~source=mockSource.source)

    mockSource.rejectGetHeightOrThrow("temporary network blip")
    let resolvedPromise = [chain]->StartBlockResolver.resolveAllOrThrow(~lowercaseAddresses=false)

    // Give the first attempt's rejection and its backoff delay a chance to run.
    await Utils.delay(50)
    mockSource.resolveGetHeightOrThrow(777)

    let resolved = await resolvedPromise
    t.expect(resolved->Array.map(c => c.startBlock)).toEqual([Config.Number(777)])
  })
})
