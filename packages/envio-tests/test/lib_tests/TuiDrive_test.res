open Vitest

describe("Tui.drive", () => {
  // The display polls on an interval, so whatever changed since the last poll
  // is only on screen if stopping draws it.
  it("Draws the latest metrics in the frame it stops on", t => {
    let calls = []
    let tui = {
      "update": (chains: array<Tui.chain>) =>
        calls->Array.push(
          `update ${chains
            ->Array.map(chain => chain.numEventsProcessed->Float.toString)
            ->Array.join(",")}`,
        ),
      "stop": () => calls->Array.push("stop"),
    }->(Utils.magic: {"update": array<Tui.chain> => unit, "stop": unit => unit} => Tui.t)
    let empty = Metrics.merge(
      [],
      ~startTime=Date.make(),
      ~metricTime=Date.make(),
      ~elapsedSeconds=0.,
      ~targetBufferSize=0,
    )
    let chain = Supervisor.configuredChains(TestConfig.default)->Array.getUnsafe(0)
    let events = ref(0.)
    let getMetrics = () => {...empty, chains: [{...chain, numEventsProcessed: events.contents}]}

    let stop = tui->Tui.drive(~getMetrics)
    events := 2.
    stop()

    t.expect(calls).toEqual(["update 0", "update 2", "stop"])
  })
})
