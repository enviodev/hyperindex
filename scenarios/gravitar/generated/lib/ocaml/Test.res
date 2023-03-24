let run = () => {
  Js.log("Running tests")
  Index.processEventBatch(MockEvents.eventBatch)->ignore
}

run()
