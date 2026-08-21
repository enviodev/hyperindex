open Vitest

describe("Utils.delayWithCancel", () => {
  beforeEach(() => Vi.useFakeTimers())
  afterEach(() => Vi.useRealTimers())

  Async.it("Resolves when the delay elapses and leaves no timer behind", async t => {
    let resolved = ref(false)
    let (promise, _cancel) = Utils.delayWithCancel(10_000)
    let _ = promise->Promise.thenResolve(() => resolved := true)

    await Vi.advanceTimersByTimeAsync(9_999)
    let beforeDue = (resolved.contents, Vi.getTimerCount())
    await Vi.advanceTimersByTimeAsync(1)

    t.expect((beforeDue, resolved.contents, Vi.getTimerCount())).toStrictEqual((
      (false, 1),
      true,
      0,
    ))
  })

  Async.it("Clears the pending timer when cancelled", async t => {
    let resolved = ref(false)
    let (promise, cancel) = Utils.delayWithCancel(10_000)
    let _ = promise->Promise.thenResolve(() => resolved := true)

    await Vi.advanceTimersByTimeAsync(5_000)
    let beforeCancel = Vi.getTimerCount()
    cancel()

    // The whole point of the helper: the losing arm of a settled race must not
    // hold a timer, and everything its continuation captured, for the rest of
    // the window.
    await Vi.advanceTimersByTimeAsync(10_000)

    t.expect((beforeCancel, Vi.getTimerCount(), resolved.contents)).toStrictEqual((1, 0, false))
  })

  Async.it("Cancelling a spent timer does nothing", async t => {
    let (promise, cancel) = Utils.delayWithCancel(10_000)
    let _ = promise->Promise.thenResolve(() => ())

    await Vi.advanceTimersByTimeAsync(10_000)
    cancel()
    cancel()

    t.expect(Vi.getTimerCount()).toBe(0)
  })
})
