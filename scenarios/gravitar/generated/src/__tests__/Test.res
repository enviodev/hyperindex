let run = () => {
  Js.log("Running tests")
  let startTime = Js.Date.now()
  Index.processEventBatch(MockEvents.eventBatch)
  ->Js.Promise2.then(_ => {
    let endTime = Js.Date.now()
    let timeTaken = endTime -. startTime
    Js.log2("time taken (ms)", timeTaken)->Js.Promise2.resolve
  })
  ->ignore
}

run()
