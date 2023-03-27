open Jest

describe("E2E Mock Event Batch", () => {
  testAsync("3 newGravitar, 3 updateGravitar", resolve => {
    Index.processEventBatch(MockEvents.eventBatch)
    ->Js.Promise2.then(_ => pass->resolve->Js.Promise2.resolve)
    ->ignore
  })
})
