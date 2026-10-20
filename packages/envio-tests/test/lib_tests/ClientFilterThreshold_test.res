open Vitest

describe("client-side address filtering", () => {
  it("switches a contract over once it holds more than 100k addresses", t => {
    t.expect(Env.clientFilterAddressThreshold).toBe(100_000)
  })
})
