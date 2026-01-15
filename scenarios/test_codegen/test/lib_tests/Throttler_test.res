open RescriptMocha

describe("Throttler", () => {
  Async.it("Schedules and throttles functions as expected", async () => {
    let throttler = Throttler.make(~intervalMillis=10, ~logger=Logging.getLogger())
    let actionsCalled = []

    throttler->Throttler.schedule(async () => actionsCalled->Js.Array2.push(1)->ignore)
    throttler->Throttler.schedule(
      async () => {
        actionsCalled->Js.Array2.push(2)->ignore
        Assert.fail("Should have throttled 2nd scheduled fn in favour of following")
      },
    )
    throttler->Throttler.schedule(async () => actionsCalled->Js.Array2.push(3)->ignore)

    Assert.deepEqual(actionsCalled, [1], ~message="Should have immediately called scheduled fn")

    await Time.resolvePromiseAfterDelay(~delayMilliseconds=9)
    Assert.deepEqual(actionsCalled, [1], ~message="Should still be called once after 9 ms")

    // Should have a second call in 1 more millisecond. Wait 3 just in case
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=3)
    Assert.deepEqual(
      actionsCalled,
      [1, 3],
      ~message="Should have called latest scheduled fn after delay",
    )
  })

  Async.it("Does not continuously increase schedule time", async () => {
    let throttler = Throttler.make(~intervalMillis=20, ~logger=Logging.getLogger())
    let actionsCalled = []
    throttler->Throttler.schedule(async () => actionsCalled->Js.Array2.push(1)->ignore)
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=10)
    throttler->Throttler.schedule(async () => actionsCalled->Js.Array2.push(2)->ignore)
    Assert.deepEqual(actionsCalled, [1], ~message="Scheduler should still be waiting for interval")
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=11)
    Assert.deepEqual(
      actionsCalled,
      [1, 2],
      ~message="Scheduler should have been called straight after the initial interval",
    )
  })

  Async.it("Does not run until previous task is finished", async () => {
    let throttler = Throttler.make(~intervalMillis=10, ~logger=Logging.getLogger())
    let actionsCalled = []
    throttler->Throttler.schedule(
      async () => {
        await Time.resolvePromiseAfterDelay(~delayMilliseconds=13)
        actionsCalled->Js.Array2.push(1)->ignore
      },
    )

    throttler->Throttler.schedule(
      async () => {
        actionsCalled->Js.Array2.push(2)->ignore
      },
    )

    Assert.deepEqual(actionsCalled, [], ~message="First task is still busy")

    await Time.resolvePromiseAfterDelay(~delayMilliseconds=11)
    Assert.deepEqual(
      actionsCalled,
      [],
      ~message="Second task has not executed even though passed interval",
    )

    await Time.resolvePromiseAfterDelay(~delayMilliseconds=5)

    Assert.deepEqual(
      actionsCalled,
      [1, 2],
      ~message="Should have finished task one and execute task two immediately",
    )
  })

  Async.it(
    "Does not immediately execute after a task has finished if below the interval",
    async () => {
      let throttler = Throttler.make(~intervalMillis=10, ~logger=Logging.getLogger())
      let actionsCalled = []
      throttler->Throttler.schedule(
        async () => {
          await Time.resolvePromiseAfterDelay(~delayMilliseconds=5)
          actionsCalled->Js.Array2.push(1)->ignore
        },
      )
      throttler->Throttler.schedule(
        async () => {
          actionsCalled->Js.Array2.push(2)->ignore
        },
      )

      Assert.deepEqual(actionsCalled, [], ~message="First task is still busy")
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=6)
      Assert.deepEqual(
        actionsCalled,
        [1],
        ~message="First action finished, second action waiting for interval",
      )

      await Time.resolvePromiseAfterDelay(~delayMilliseconds=5)
      Assert.deepEqual(
        actionsCalled,
        [1, 2],
        ~message="Second action should have been called after the interval as passed",
      )
    },
  )

  Async.it(
    "Continues processing after a task times out (does not get stuck)",
    async () => {
      // Use a very short timeout for testing
      let throttler = Throttler.make(
        ~intervalMillis=10,
        ~logger=Logging.getLogger(),
        ~executionTimeoutMillis=50,
      )
      let actionsCalled = []

      // Schedule a task that will take longer than the timeout
      throttler->Throttler.schedule(
        async () => {
          // This will take 100ms, but timeout is 50ms
          await Time.resolvePromiseAfterDelay(~delayMilliseconds=100)
          actionsCalled->Js.Array2.push(1)->ignore
        },
      )

      // Wait for the timeout to trigger
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=60)

      // Schedule another task - this should work even after the timeout
      throttler->Throttler.schedule(
        async () => {
          actionsCalled->Js.Array2.push(2)->ignore
        },
      )

      // Wait for the second task to execute
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=15)

      // The first task should not have completed (timed out),
      // but the second should have been processed
      Assert.deepEqual(
        actionsCalled,
        [2],
        ~message="Throttler should continue processing after a timeout",
      )
    },
  )

  Async.it(
    "Continues processing after a task throws an exception",
    async () => {
      let throttler = Throttler.make(~intervalMillis=10, ~logger=Logging.getLogger())
      let actionsCalled = []

      // Schedule a task that throws
      throttler->Throttler.schedule(
        async () => {
          Js.Exn.raiseError("Test error")
        },
      )

      // Wait for the failing task to complete
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=5)

      // Schedule another task - this should work even after the exception
      throttler->Throttler.schedule(
        async () => {
          actionsCalled->Js.Array2.push(1)->ignore
        },
      )

      // Wait for the second task to execute
      await Time.resolvePromiseAfterDelay(~delayMilliseconds=15)

      Assert.deepEqual(
        actionsCalled,
        [1],
        ~message="Throttler should continue processing after an exception",
      )
    },
  )
})
