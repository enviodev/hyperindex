open RescriptMocha

describe_only("Debouncer", () => {
  Async.it("Schedules and debounces functions as expected", async () => {
    let debouncer = Debouncer.make(~delayMillis=10, ~logger=Logging.logger)
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
})
