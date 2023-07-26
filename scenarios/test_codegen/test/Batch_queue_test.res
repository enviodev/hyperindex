open RescriptMocha
module MochaPromise = RescriptMocha.Promise
open Mocha

let queue: BatchQueue.t<int> = BatchQueue.make(~maxQueueLength=3, ~maxBatchChunkSize=3, ())

let mockBatch = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

describe("Batch Queue Tests", () => {
  MochaPromise.it("Queue chunks correctly and works with async calls", async () => {
    //Awaiting here will block since pushing won't be able to add more than
    //the queue length of 3 until something has been popped
    //queue will take the batch and chunk it into uniform batches of max 3 size
    let _unawaitedPromise = queue->BatchQueue.push(mockBatch)

    //popping first item enables pushing to finish
    let firstItem = await queue->BatchQueue.pop
    let secondItem = await queue->BatchQueue.pop
    let thirdItem = await queue->BatchQueue.pop
    let fourthItem = await queue->BatchQueue.pop

    Assert.deep_equal(firstItem, [1, 2, 3])
    Assert.deep_equal(secondItem, [4, 5, 6])
    Assert.deep_equal(thirdItem, [7, 8, 9])
    Assert.deep_equal(fourthItem, [10])
  })
})
