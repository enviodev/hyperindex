open RescriptMocha

describe_only("Debouncer", () => {
  Async.it("Schedules and debounces functions as expected", async () => {
    let debouncer = Debouncer.make(~intervalMillis=10, ~logger=Logging.logger)
    let counter = ref(0)

    debouncer->Debouncer.schedule(async () => counter := 1)
    debouncer->Debouncer.schedule(
      async () => {
        Assert.fail("Should have debounced 2nd scheduled fn in favour of following")
      },
    )
    debouncer->Debouncer.schedule(async () => counter := 3)

    Assert.equal(counter.contents, 1, ~message="Should have immediately called scheduled fn")
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=11)
    Assert.equal(counter.contents, 3, ~message="Should have called latest scheduled fn after delay")
  })

  Async.it("Does not continuously increase schedule time", async () => {
    let debouncer = Debouncer.make(~intervalMillis=20, ~logger=Logging.logger)
    let counter = ref(0)
    debouncer->Debouncer.schedule(async () => counter := 1)
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=10)
    debouncer->Debouncer.schedule(async () => counter := 2)
    Assert.equal(counter.contents, 1, ~message="Scheduler should still be waiting for interval")
    await Time.resolvePromiseAfterDelay(~delayMilliseconds=11)
    Assert.equal(
      counter.contents,
      2,
      ~message="Scheduler should have been called straight after the initial interval",
    )
  })

  Async.it("Does not run until previous task is finished", async () => {
    let debouncer = Debouncer.make(~intervalMillis=10, ~logger=Logging.logger)
    let actionsCalled = []
    debouncer->Debouncer.schedule(
      async () => {
        await Time.resolvePromiseAfterDelay(~delayMilliseconds=13)
        actionsCalled->Js.Array2.push(1)->ignore
      },
    )

    debouncer->Debouncer.schedule(
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
})
