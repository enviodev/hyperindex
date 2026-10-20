open Vitest

// `Main` logs a fatal failure through `ErrorHandling.log`; scenario runs replace
// that `onError`, so the line is checked here.
describe("ErrorHandling.log", () => {
  it("headlines a failure without a message with the error's own", t => {
    let logger = Logger.makeInMemory()
    ErrorHandling.make(
      JsError.make("No events found")->(Utils.magic: JsError.t => exn),
      ~logger,
    )->ErrorHandling.log
    ErrorHandling.make(%raw(`"thrown string"`), ~logger)->ErrorHandling.log
    t.expect(
      logger
      ->Logger.inMemoryLines
      ->Array.map(line => (line->Dict.get("level"), line->Dict.get("msg"))),
    ).toEqual([
      (Some(JSON.String("error")), Some(JSON.String("No events found"))),
      (Some(JSON.String("error")), Some(JSON.String("Unexpected error"))),
    ])
  })
})
