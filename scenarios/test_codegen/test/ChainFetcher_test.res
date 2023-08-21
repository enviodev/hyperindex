open RescriptMocha
open Mocha
let {
  it: it_promise,
  it_only: it_promise_only,
  it_skip: it_skip_promise,
  before: before_promise,
} = module(RescriptMocha.Promise)

describe("Chain Fetcher", () => {
  it_promise("No test yet", async () => {
    ()
  })
})
