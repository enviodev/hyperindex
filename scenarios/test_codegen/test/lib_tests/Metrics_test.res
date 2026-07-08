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

describe("Metrics.renderSourceRequests", () => {
  it("Hand-rolls both HELP/TYPE blocks with one sample pair per (source, chain, method)", t => {
    let rendered = Metrics.renderSourceRequests(
      ~samples=[
        {SourceManager.sourceName: "HyperSync", chainId: 1, method: "getLogs", count: 3, seconds: 1.5},
        {
          SourceManager.sourceName: "RPC (host)",
          chainId: 137,
          method: "heightSubscription",
          count: 1,
          seconds: 0.,
        },
      ],
    )

    t.expect(rendered).toBe(
      `
# HELP envio_source_request_total The number of requests made to data sources.
# TYPE envio_source_request_total counter
envio_source_request_total{source="HyperSync",chainId="1",method="getLogs"} 3
envio_source_request_total{source="RPC (host)",chainId="137",method="heightSubscription"} 1
# HELP envio_source_request_seconds_total Cumulative time spent on data source requests.
# TYPE envio_source_request_seconds_total counter
envio_source_request_seconds_total{source="HyperSync",chainId="1",method="getLogs"} 1.5
envio_source_request_seconds_total{source="RPC (host)",chainId="137",method="heightSubscription"} 0`,
    )
  })

  it("Renders only the headers when there are no samples", t => {
    let rendered = Metrics.renderSourceRequests(~samples=[])

    t.expect(rendered).toBe(
      `
# HELP envio_source_request_total The number of requests made to data sources.
# TYPE envio_source_request_total counter
# HELP envio_source_request_seconds_total Cumulative time spent on data source requests.
# TYPE envio_source_request_seconds_total counter`,
    )
  })
})

describe("Metrics.collect", () => {
  Async.it("Returns the base registry metrics untouched when there is no state", async t => {
    let collected = await Metrics.collect(~state=None)
    let base = await PromClient.defaultRegister->PromClient.metrics
    t.expect(collected).toBe(base)
  })
})
