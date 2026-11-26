open Vitest

describe("client-side address filtering", () => {
  it("switches a contract over once it holds more than 100k addresses", t => {
    t.expect(IndexerEnv.read().clientFilterAddressThreshold).toBe(100_000)
  })
})
