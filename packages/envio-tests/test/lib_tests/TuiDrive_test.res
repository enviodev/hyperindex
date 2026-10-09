open Vitest

let config = TestConfig.fromUserApi(`
name: test-config
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
  - id: 137
    start_block: 0
    contracts:
      - name: Poap
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`)

describe("Tui.drive", () => {
  // The display polls on an interval, so whatever changed since the last poll
  // is only on screen if stopping draws it.
  it("Draws the latest metrics in the frame it stops on", t => {
    let calls = []
    let tui = {
      "update": (chains: array<Tui.chain>) =>
        calls->Array.push(`update ${chains->Array.map(chain => chain.chainId)->Array.join(",")}`),
      "stop": () => calls->Array.push("stop"),
    }->(Utils.magic: {"update": array<Tui.chain> => unit, "stop": unit => unit} => Tui.t)
    let empty = Metrics.merge(
      [],
      ~startTime=Date.make(),
      ~metricTime=Date.make(),
      ~elapsedSeconds=0.,
      ~targetBufferSize=0,
    )
    let allChains = Supervisor.configuredChains(config)
    let shown = ref(1)
    let getMetrics = () => {...empty, chains: allChains->Array.slice(~start=0, ~end=shown.contents)}

    let stop = tui->Tui.drive(~getMetrics)
    shown := 2
    stop()

    t.expect(calls).toEqual(["update 1", "update 1,137", "stop"])
  })
})
