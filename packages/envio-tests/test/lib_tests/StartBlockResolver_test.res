open Vitest

let chainId = 1->ChainId.fromInt

// Short enough that a test asserting the give-up path doesn't sit out a real
// backoff, long enough that the retry tests can observe an attempt in flight.
let fastOptions: StartBlockResolver.options = {
  attemptTimeoutMs: 1000,
  retryIntervalMs: 1,
  deadlineMs: 1000,
}

let resolve = (sources, ~options=fastOptions) =>
  StartBlockResolver.resolveOrThrow(
    ~chainId,
    ~sources,
    ~logger=Logging.createChild(~params={"test": true}),
    ~options,
  )

let errorMessageOf = async (resolving: promise<'a>) =>
  try {
    let _ = await resolving
    None
  } catch {
  | JsExn(e) => e->JsExn.message
  }

describe("StartBlockResolver", () => {
  Async.it("answers with the head the source reports, from one request", async t => {
    let mockSource = MockSource.make([#getHeightOrThrow], ~chainId=1, ~autoHeight=12345)

    let head = await [mockSource.source]->resolve

    t.expect((head, mockSource.getHeightOrThrowCalls->Array.length)).toEqual((12345, 1))
  })

  Async.it("never subscribes to a height stream", async t => {
    let mockSource = MockSource.make(
      [#getHeightOrThrow, #createHeightSubscription],
      ~chainId=1,
      ~autoHeight=500,
    )

    let head = await [mockSource.source]->resolve

    // Resolving a start block is one question with one answer. A stream is for
    // a height that keeps moving, which is the indexer loop's business.
    t.expect((head, mockSource.heightSubscriptionCalls->Array.length)).toEqual((500, 0))
  })

  Async.it("retries the same source until it answers", async t => {
    let mockSource = MockSource.make([#getHeightOrThrow], ~chainId=1)

    let resolving = [mockSource.source]->resolve
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

    t.expect((await resolving, mockSource.getHeightOrThrowCalls->Array.length)).toEqual((777, 2))
  })

  Async.it("falls over to a fallback source when the primary won't answer", async t => {
    let primary = MockSource.make([#getHeightOrThrow], ~chainId=1)
    let fallback = MockSource.make(
      [#getHeightOrThrow],
      ~chainId=1,
      ~sourceFor=Source.Fallback,
      ~autoHeight=999,
    )

    let resolving = [primary.source, fallback.source]->resolve
    await Scenario.waitUntil(
      () => primary.getHeightOrThrowCalls->Array.length === 1,
      ~message="the primary's height request",
    )
    primary.rejectGetHeightOrThrow("primary is down")

    t.expect((await resolving, fallback.getHeightOrThrowCalls->Array.length)).toEqual((999, 1))
  })

  Async.it("gives up with a clear error once the deadline passes", async t => {
    // Answers nothing, ever.
    let mockSource = MockSource.make([#getHeightOrThrow], ~chainId=1)

    let error =
      await [mockSource.source]
      ->resolve(~options={attemptTimeoutMs: 20, retryIntervalMs: 1, deadlineMs: 2000})
      ->errorMessageOf

    t.expect(error).toEqual(
      Some(`Chain 1: couldn't resolve the "latest" start block - no source answered a height request within 2s. Check the chain's RPC/HyperSync endpoints and ENVIO_API_TOKEN, then start again.`),
    )
  })

  Async.it("stops asking the source once it has given up", async t => {
    let mockSource = MockSource.make([#getHeightOrThrow], ~chainId=1)

    let _ =
      await [mockSource.source]
      ->resolve(~options={attemptTimeoutMs: 20, retryIntervalMs: 1, deadlineMs: 2000})
      ->errorMessageOf
    let callsAtGiveUp = mockSource.getHeightOrThrowCalls->Array.length
    await Utils.delay(100)

    t.expect(mockSource.getHeightOrThrowCalls->Array.length - callsAtGiveUp).toEqual(0)
  })

  Async.it("says so when the chain has no source that can serve a height", async t => {
    let realtimeOnly = MockSource.make([#getHeightOrThrow], ~chainId=1, ~sourceFor=Source.Realtime)

    let error = await [realtimeOnly.source]->resolve->errorMessageOf

    t.expect(error).toEqual(
      Some(`Chain 1: can't resolve the "latest" start block because the chain has no source to read a height from.`),
    )
  })
})
