open Vitest

let makeChain = (~startBlock=0, ~isLatestStartBlock, ~endBlock=?, ~source): Config.chain => {
  name: "Chain1",
  id: 1->ChainId.fromInt,
  ecosystem: Ecosystem.Evm,
  startBlock,
  isLatestStartBlock,
  ?endBlock,
  maxReorgDepth: 10,
  blockLag: 0,
  contracts: [],
  sourceConfig: Config.CustomSources([source]),
}

let errorMessageOf = async (resolving: promise<'a>) =>
  try {
    let _ = await resolving
    None
  } catch {
  | JsExn(e) => e->JsExn.message
  }

describe("StartBlockResolver", () => {
  Async.it(
    "leaves a chain with a fixed start block alone, even one past its end_block",
    async t => {
      let mockSource = MockSource.make([], ~chainId=1)
      let chain = makeChain(
        ~startBlock=100,
        ~endBlock=50,
        ~isLatestStartBlock=false,
        ~source=mockSource.source,
      )

      let resolved = await [chain]->StartBlockResolver.resolveAllOrThrow(~lowercaseAddresses=false)

      t.expect((resolved, mockSource.getHeightOrThrowCalls->Array.length)).toEqual(([chain], 0))
    },
  )

  Async.it("resolves latest to the source's current height", async t => {
    let mockSource = MockSource.make([#getHeightOrThrow], ~chainId=1, ~autoHeight=12345)
    let chain = makeChain(~isLatestStartBlock=true, ~source=mockSource.source)

    let resolved = await [chain]->StartBlockResolver.resolveAllOrThrow(~lowercaseAddresses=false)

    t.expect((
      resolved->Array.map(c => c.startBlock),
      mockSource.getHeightOrThrowCalls->Array.length,
    )).toEqual(([12345], 1))
  })

  Async.it("throws a clear error when latest resolves past end_block", async t => {
    let mockSource = MockSource.make([#getHeightOrThrow], ~chainId=1, ~autoHeight=100)
    let chain = makeChain(~isLatestStartBlock=true, ~endBlock=50, ~source=mockSource.source)

    let error = await [chain]
    ->StartBlockResolver.resolveAllOrThrow(~lowercaseAddresses=false)
    ->errorMessageOf

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
        isLatestStartBlock: true,
        sourceConfig: Config.CustomSources([mockSource.source]),
      }

      let error = await [chain]
      ->StartBlockResolver.resolveAllOrThrow(~lowercaseAddresses=false)
      ->errorMessageOf

      t.expect(error).toEqual(
        Some(`Chain 1: contract "Gravatar" has start_block 100, but the chain's "latest" start block resolved to 500. A contract can't start before its chain does - remove the contract's start_block, or pin the chain's start_block to a fixed value instead of "latest".`),
      )
    },
  )

  Async.it("retries a failing height request with backoff until one succeeds", async t => {
    let mockSource = MockSource.make([#getHeightOrThrow], ~chainId=1)
    let chain = makeChain(~isLatestStartBlock=true, ~source=mockSource.source)

    let resolving =
      [chain]->StartBlockResolver.resolveAllOrThrow(
        ~lowercaseAddresses=false,
        ~getHeightRetryInterval=(~retry as _) => 1,
      )
    await Scenario.waitUntil(
      () => mockSource.getHeightOrThrowCalls->Array.length === 1,
      ~message="the first height request",
    )
    mockSource.rejectGetHeightOrThrow("temporary network blip")
    await Scenario.waitUntil(
      () => mockSource.getHeightOrThrowCalls->Array.length === 2,
      ~message="the retried height request",
    )
    mockSource.resolveGetHeightOrThrow(777)

    let resolved = await resolving
    t.expect((
      resolved->Array.map(c => c.startBlock),
      mockSource.getHeightOrThrowCalls->Array.length,
    )).toEqual(([777], 2))
  })

  Async.it("stops polling the source once the deadline gave up", async t => {
    let mockSource = MockSource.make([#getHeightOrThrow], ~chainId=1)
    let chain = makeChain(~isLatestStartBlock=true, ~source=mockSource.source)

    let error = await [chain]
    ->StartBlockResolver.resolveAllOrThrow(
      ~lowercaseAddresses=false,
      ~getHeightRetryInterval=(~retry as _) => 1,
      ~deadlineMs=50,
    )
    ->errorMessageOf
    let callsAtGiveUp = mockSource.getHeightOrThrowCalls->Array.length

    // The request the resolver was waiting on when it gave up. Failing it is
    // what would send a still-running poll loop straight into its next retry.
    mockSource.rejectGetHeightOrThrow("temporary network blip")
    await Utils.delay(50)

    t.expect((
      error->Option.isSome,
      mockSource.getHeightOrThrowCalls->Array.length - callsAtGiveUp,
    )).toEqual((true, 0))
  })

  Async.it("gives up with a clear error once the deadline passes", async t => {
    // Never answers.
    let mockSource = MockSource.make([#getHeightOrThrow], ~chainId=1)
    let chain = makeChain(~isLatestStartBlock=true, ~source=mockSource.source)

    let error = await [chain]
    ->StartBlockResolver.resolveAllOrThrow(~lowercaseAddresses=false, ~deadlineMs=1000)
    ->errorMessageOf

    t.expect(error).toEqual(
      Some(`Chain 1: couldn't resolve the "latest" start block - no source answered a height request within 1s. Check the chain's RPC/HyperSync endpoints and ENVIO_API_TOKEN, then start again.`),
    )
  })
})
