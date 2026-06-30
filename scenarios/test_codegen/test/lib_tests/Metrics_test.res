open Vitest

describe("Metrics.renderGauge", () => {
  it("Hand-rolls prometheus gauge text with one sample per chain", t => {
    let rendered = Metrics.renderGauge(
      ~name="envio_indexing_addresses",
      ~help="The number of addresses indexed on chain.",
      ~chains=Dict.fromArray([("1", 3), ("137", 0)]),
      ~value=count => count,
    )

    t.expect(rendered).toBe(
      `# HELP envio_indexing_addresses The number of addresses indexed on chain.
# TYPE envio_indexing_addresses gauge
envio_indexing_addresses{chainId="1"} 3
envio_indexing_addresses{chainId="137"} 0`,
    )
  })

  it("Renders only the header when there are no chains", t => {
    let rendered = Metrics.renderGauge(
      ~name="envio_indexing_addresses",
      ~help="help",
      ~chains=Dict.make(),
      ~value=count => count,
    )

    t.expect(rendered).toBe(`# HELP envio_indexing_addresses help
# TYPE envio_indexing_addresses gauge`)
  })
})

describe("Metrics.collect", () => {
  Async.it("Returns the base registry metrics untouched when there is no state", async t => {
    let collected = await Metrics.collect(~state=None)
    let base = await PromClient.defaultRegister->PromClient.metrics
    t.expect(collected).toBe(base)
  })
})
