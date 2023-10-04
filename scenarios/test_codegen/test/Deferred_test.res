open RescriptMocha
open Mocha
let {it} = module(RescriptMocha.Promise)

describe("Deferred", () => {
  it("empty array resolves deferred", async () => {
    await []->Deferred.mapArrayDeferred((_, res, _) => res())->Deferred.asPromise
  })
  it("mapped array performs callback and resolves correctly", async () => {
    let initial = [1, 2, 3]
    let doubled =
      await initial->Deferred.mapArrayDeferred((item, res, _) => res(item * 2))->Deferred.asPromise

    Assert.deep_equal(doubled, [2, 4, 6])
  })
})
