open Vitest

let makeChain = (~startBlock, ~endBlock=?, ~sources): Config.chain => {
  name: "Chain1",
  id: 1->ChainId.fromInt,
  ecosystem: Ecosystem.Evm,
  startBlock,
  ?endBlock,
  maxReorgDepth: 10,
  blockLag: 0,
  contracts: [],
  sourceConfig: Config.CustomSources(sources),
}

let resolveAll = (chains, ~getHeightRetryInterval=(~retry as _) => 1) =>
  chains->StartBlockResolver.resolveAllOrThrow(~lowercaseAddresses=false, ~getHeightRetryInterval)

let errorMessageOf = async (resolving: promise<'a>) =>
  try {
    let _ = await resolving
    None
  } catch {
  | JsExn(e) => e->JsExn.message
  }

describe("StartBlockResolver", () => {
  Async.it("leaves a fixed start block alone, even one past its end_block", async t => {
    let mockSource = MockSource.make([], ~chainId=1)
    let chain = makeChain(
      ~startBlock=Config.Block(100),
      ~endBlock=50,
      ~sources=[mockSource.source],
    )

    let resolved = await [chain]->resolveAll

    t.expect((resolved, mockSource.getHeightOrThrowCalls->Array.length)).toEqual(([chain], 0))
  })

  Async.it("resolves latest to the source's current height", async t => {
    let mockSource = MockSource.make([#getHeightOrThrow], ~chainId=1, ~autoHeight=12345)
    let chain = makeChain(~startBlock=Config.Latest, ~sources=[mockSource.source])

    let resolved = await [chain]->resolveAll

    t.expect((
      resolved->Array.map(c => c.startBlock),
      mockSource.getHeightOrThrowCalls->Array.length,
    )).toEqual(([Config.Block(12345)], 1))
  })

  Async.it("never subscribes to a height stream", async t => {
    let mockSource = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~chainId=1,
      ~autoHeight=500,
    )
    let chain = makeChain(~startBlock=Config.Latest, ~sources=[mockSource.source])

    let resolved = await [chain]->resolveAll

    // Reading a start block is one question with one answer. A stream is for a
    // height that keeps moving, which is the indexer loop's business.
    t.expect((
      resolved->Array.map(c => c.startBlock),
      mockSource.heightSubscriptionCalls->Array.length,
    )).toEqual(([Config.Block(500)], 0))
  })

  Async.it("keeps retrying a failing source instead of giving up", async t => {
    let mockSource = MockSource.make([#getHeightOrThrow], ~chainId=1)
    let chain = makeChain(~startBlock=Config.Latest, ~sources=[mockSource.source])

    let resolving = [chain]->resolveAll
    await Scenario.waitUntil(
      () => mockSource.getHeightOrThrowCalls->Array.length === 1,
      ~message="the first height request",
    )
    mockSource.rejectGetHeightOrThrow("temporary network blip")
    await Scenario.waitUntil(
      () => mockSource.getHeightOrThrowCalls->Array.length === 2,
      ~message="the retried height request",
    )
    mockSource.rejectGetHeightOrThrow("another blip")
    await Scenario.waitUntil(
      () => mockSource.getHeightOrThrowCalls->Array.length === 3,
      ~message="a second retry, so failures never exhaust the resolver",
    )
    mockSource.resolveGetHeightOrThrow(777)

    let resolved = await resolving
    t.expect(resolved->Array.map(c => c.startBlock)).toEqual([Config.Block(777)])
  })

  Async.it("fails over to a fallback source when the primary stalls", async t => {
    let primary = MockSource.make([#getHeightOrThrow], ~chainId=1)
    let fallback = MockSource.make(
      [#getHeightOrThrow],
      ~chainId=1,
      ~sourceFor=Source.Fallback,
      ~autoHeight=999,
    )
    let chain = makeChain(
      ~startBlock=Config.Latest,
      ~sources=[primary.source, fallback.source],
    )

    let resolved =
      await [chain]->StartBlockResolver.resolveAllOrThrow(
        ~lowercaseAddresses=false,
        ~getHeightRetryInterval=(~retry as _) => 1,
        // The window the primary gets to itself before a fallback is recruited.
        ~newBlockStallTimeout=1,
      )

    t.expect((
      resolved->Array.map(c => c.startBlock),
      fallback.getHeightOrThrowCalls->Array.length,
    )).toEqual(([Config.Block(999)], 1))
  })

  Async.it("with `Once`, gives up after one attempt per source and says why", async t => {
    let primary = MockSource.make([#getHeightOrThrow], ~chainId=1)
    let fallback = MockSource.make([#getHeightOrThrow], ~chainId=1, ~sourceFor=Source.Fallback)
    let chain = makeChain(~startBlock=Config.Latest, ~sources=[primary.source, fallback.source])

    let resolving =
      [chain]
      ->StartBlockResolver.resolveAllOrThrow(
        ~lowercaseAddresses=false,
        ~retry=StartBlockResolver.Once,
      )
      ->errorMessageOf
    await Scenario.waitUntil(
      () => primary.getHeightOrThrowCalls->Array.length === 1,
      ~message="the primary's one attempt",
    )
    primary.rejectGetHeightOrThrow(JsError.make("primary is down"))
    await Scenario.waitUntil(
      () => fallback.getHeightOrThrowCalls->Array.length === 1,
      ~message="the fallback's one attempt",
    )
    fallback.rejectGetHeightOrThrow(JsError.make("fallback is down too"))

    let error = await resolving
    t.expect((
      error,
      primary.getHeightOrThrowCalls->Array.length,
      fallback.getHeightOrThrowCalls->Array.length,
    )).toEqual((
      Some(`Chain 1: couldn't resolve the "latest" start block - no source answered a height request.
  MockSource: primary is down
  MockSource: fallback is down too`),
      1,
      1,
    ))
  })

  Async.it("says what's wrong when no source can serve historical sync", async t => {
    // Every candidate filtered out leaves nothing to ask, which is a config
    // error rather than an unanswered request - and it has to read as the same
    // config error on both retry policies.
    let realtimeOnly = MockSource.make([#getHeightOrThrow], ~chainId=1, ~sourceFor=Source.Realtime)
    let chain = makeChain(~startBlock=Config.Latest, ~sources=[realtimeOnly.source])

    let error =
      await [chain]
      ->StartBlockResolver.resolveAllOrThrow(
        ~lowercaseAddresses=false,
        ~retry=StartBlockResolver.Once,
      )
      ->errorMessageOf

    t.expect((error, realtimeOnly.getHeightOrThrowCalls->Array.length)).toEqual((
      Some("Invalid configuration, no data-source for historical sync provided"),
      0,
    ))
  })

  Async.it("with `Once`, takes the first source that answers", async t => {
    let primary = MockSource.make([#getHeightOrThrow], ~chainId=1)
    let fallback = MockSource.make(
      [#getHeightOrThrow],
      ~chainId=1,
      ~sourceFor=Source.Fallback,
      ~autoHeight=4242,
    )
    let chain = makeChain(~startBlock=Config.Latest, ~sources=[primary.source, fallback.source])

    let resolving =
      [chain]->StartBlockResolver.resolveAllOrThrow(
        ~lowercaseAddresses=false,
        ~retry=StartBlockResolver.Once,
      )
    await Scenario.waitUntil(
      () => primary.getHeightOrThrowCalls->Array.length === 1,
      ~message="the primary's one attempt",
    )
    primary.rejectGetHeightOrThrow(JsError.make("primary is down"))

    let resolved = await resolving
    t.expect(resolved->Array.map(c => c.startBlock)).toEqual([Config.Block(4242)])
  })

  // `start_block: latest` is offered on every ecosystem, and each one builds its
  // own address store and sources on the way to a height request. Driving the
  // real per-ecosystem chain config through the resolver is what keeps the
  // feature from being quietly EVM-only.
  [
    (
      "Fuel",
      `
name: fuel-latest
ecosystem: fuel
chains:
  - id: 0
    start_block: latest
`,
    ),
    (
      "SVM",
      `
name: svm-latest
ecosystem: svm
chains:
  - id: solana
    start_slot: latest
    rpc: https://api.mainnet-beta.solana.com
`,
    ),
  ]->Array.forEach(((ecosystem, configYaml)) => {
    Async.it(`resolves latest on ${ecosystem}`, async t => {
      let {config} = InternalTestIndexer.fromUserApi(~configYaml)
      let configChain = config.chainMap->ChainMap.values->Array.getUnsafe(0)
      let mockSource = MockSource.make(
        [#getHeightOrThrow],
        ~chainId=configChain.id->ChainId.toInt,
        ~autoHeight=8888,
      )
      let chain = {
        ...configChain,
        sourceConfig: Config.CustomSources([mockSource.source]),
      }

      let resolved = await [chain]->resolveAll

      t.expect((
        configChain.startBlock,
        resolved->Array.map(c => c.startBlock),
      )).toEqual((Config.Latest, [Config.Block(8888)]))
    })
  })

  Async.it("throws a clear error when latest resolves past end_block", async t => {
    let mockSource = MockSource.make([#getHeightOrThrow], ~chainId=1, ~autoHeight=100)
    let chain = makeChain(~startBlock=Config.Latest, ~endBlock=50, ~sources=[mockSource.source])

    let error = await [chain]->resolveAll->errorMessageOf

    t.expect(error).toEqual(
      Some(`Chain 1: the "latest" start block resolved to 100, which is past the configured end_block (50). There is nothing to index - remove end_block, raise it above the chain's current head, or pin start_block to a fixed value instead of "latest".`),
    )
  })

  Async.it(
    "throws before anything is persisted when a contract start block predates the resolved head",
    async t => {
      let {config} = InternalTestIndexer.fromUserApi(
        ~configYaml=`
name: latest-contract-start-block
contracts:
  - name: Gravatar
    events:
      - event: "TestEvent()"
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        start_block: 100
`,
      )
      let mockSource = MockSource.make([#getHeightOrThrow], ~chainId=1, ~autoHeight=500)
      let chain = {
        ...config.chainMap->ChainMap.values->Array.getUnsafe(0),
        startBlock: Config.Latest,
        sourceConfig: Config.CustomSources([mockSource.source]),
      }

      let error = await [chain]->resolveAll->errorMessageOf

      t.expect(error).toEqual(
        Some(`Chain 1: contract "Gravatar" has start_block 100, but the chain's "latest" start block resolved to 500. A contract can't start before its chain does - remove the contract's start_block, or pin the chain's start_block to a fixed value instead of "latest".`),
      )
    },
  )
})
