open Jest
open Expect

describe("First test", () => {
  test("test 1", () => {
    Js.log("test1")
    expect(1)->toBe(1)
  })
})
