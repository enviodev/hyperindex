open Vitest

describe("Worker.onParentMessage", () => {
  Async.it("Holds a request that arrived before the indexer could handle it", async t => {
    Worker.listen()
    NodeJs.Process.emitMessage(Worker.SyncCache({}))->ignore

    let handled = []
    Worker.onParentMessage(message => handled->Array.push(message))
    NodeJs.Process.emitMessage(Worker.SyncCache({}))->ignore

    t.expect(handled).toStrictEqual([Worker.SyncCache({}), Worker.SyncCache({})])
  })
})
