open Vitest

describe("Throttler", () => {
  Async.itWithOptions("Schedules and throttles functions as expected", {retry: 3}, async t => {
    let throttler = Throttler.make(~intervalMillis=10, ~logger=Logging.getLogger())
    let actionsCalled = []

    throttler->Throttler.schedule(async () => actionsCalled->Array.push(1)->ignore)
    throttler->Throttler.schedule(
      async () => {
        actionsCalled->Array.push(2)->ignore
        JsError.throwWithMessage("Should have throttled 2nd scheduled fn in favour of following")
      },
    )
    throttler->Throttler.schedule(async () => actionsCalled->Array.push(3)->ignore)

    t.expect(actionsCalled, ~message="Should have immediately called scheduled fn").toEqual([1])

    await Time.resolvePromiseAfterDelay(~delayMilliseconds=9)
    t.expect(actionsCalled, ~message="Should still be called once after 9 ms").toEqual([1])

    // Should have a second call in 1 more millisecond. Wait 3 just in case
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=3)
    t.expect(actionsCalled, ~message="Should have called latest scheduled fn after delay").toEqual([
      1,
      3,
    ])
  })

  Async.itWithOptions("Does not continuously increase schedule time", {retry: 3}, async t => {
    let throttler = Throttler.make(~intervalMillis=20, ~logger=Logging.getLogger())
    let actionsCalled = []
    throttler->Throttler.schedule(async () => actionsCalled->Array.push(1)->ignore)
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=10)
    throttler->Throttler.schedule(async () => actionsCalled->Array.push(2)->ignore)
    t.expect(actionsCalled, ~message="Scheduler should still be waiting for interval").toEqual([1])
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=11)
    t.expect(
      actionsCalled,
      ~message="Scheduler should have been called straight after the initial interval",
    ).toEqual([1, 2])
  })

  Async.it("Does not run until previous task is finished", async t => {
    let throttler = Throttler.make(~intervalMillis=10, ~logger=Logging.getLogger())
    let actionsCalled = []
    throttler->Throttler.schedule(
      async () => {
        await Time.resolvePromiseAfterDelay(~delayMilliseconds=13)
        actionsCalled->Array.push(1)->ignore
      },
    )

    throttler->Throttler.schedule(
      async () => {
        actionsCalled->Array.push(2)->ignore
      },
    )

    t.expect(actionsCalled, ~message="First task is still busy").toEqual([])

    await Time.resolvePromiseAfterDelay(~delayMilliseconds=11)
    t.expect(
      actionsCalled,
      ~message="Second task has not executed even though passed interval",
    ).toEqual([])

    await Time.resolvePromiseAfterDelay(~delayMilliseconds=5)

    t.expect(
      actionsCalled,
      ~message="Should have finished task one and execute task two immediately",
    ).toEqual([1, 2])
  })

  Async.it(
    "Does not immediately execute after a task has finished if below the interval",
    async t => {
      let throttler = Throttler.make(~intervalMillis=10, ~logger=Logging.getLogger())
      let actionsCalled = []
      throttler->Throttler.schedule(
        async () => {
          await Time.resolvePromiseAfterDelay(~delayMilliseconds=5)
          actionsCalled->Array.push(1)->ignore
        },
      )
      throttler->Throttler.schedule(
        async () => {
          actionsCalled->Array.push(2)->ignore
        },
      )

      t.expect(actionsCalled, ~message="First task is still busy").toEqual([])
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=6)
      t.expect(
        actionsCalled,
        ~message="First action finished, second action waiting for interval",
      ).toEqual([1])

      await Time.resolvePromiseAfterDelay(~delayMilliseconds=5)
      t.expect(
        actionsCalled,
        ~message="Second action should have been called after the interval as passed",
      ).toEqual([1, 2])
    },
  )
})
