open Vitest

describe("Metrics rendering helpers", () => {
  it("Renders metrics separated by a blank line, keeping 3 decimals after the point", t => {
    let b: Metrics.builder = {out: ""}
    b->Metrics.single(
      ~name="envio_preload_seconds",
      ~help="Cumulative preload time.",
      ~kind="counter",
      ~value=816.8360346669994,
    )
    b->Metrics.series(
      ~name="envio_indexing_addresses",
      ~help="The number of addresses indexed on chain.",
      ~kind="gauge",
      ~entries=[(`{chainId="1"}`, 3.), (`{chainId="137"}`, 0.)],
      ~value=v => v,
    )

    t.expect(b.out).toBe(`# HELP envio_preload_seconds Cumulative preload time.
# TYPE envio_preload_seconds counter
envio_preload_seconds 816.836

# HELP envio_indexing_addresses The number of addresses indexed on chain.
# TYPE envio_indexing_addresses gauge
envio_indexing_addresses{chainId="1"} 3
envio_indexing_addresses{chainId="137"} 0`)
  })

  it("Escapes quotes, backslashes and newlines in label values", t => {
    t.expect(`weird "name" \\ with
newline`->Metrics.escapeLabelValue).toBe(`weird \\"name\\" \\\\ with\\nnewline`)
  })

  it("Renders only the header for a series without entries and skips seriesOpt None samples", t => {
    let b: Metrics.builder = {out: ""}
    b->Metrics.series(
      ~name="envio_indexing_end_block",
      ~help="The block number to stop indexing at.",
      ~kind="gauge",
      ~entries=[],
      ~value=v => v,
    )
    b->Metrics.seriesOpt(
      ~name="envio_source_request_seconds_total",
      ~help="Cumulative time spent on data source requests.",
      ~kind="counter",
      ~entries=[(`{method="getLogs"}`, 1.5), (`{method="heightSubscription"}`, 0.)],
      ~value=v => v !== 0. ? Some(v) : None,
    )

    t.expect(b.out).toBe(`# HELP envio_indexing_end_block The block number to stop indexing at.
# TYPE envio_indexing_end_block gauge

# HELP envio_source_request_seconds_total Cumulative time spent on data source requests.
# TYPE envio_source_request_seconds_total counter
envio_source_request_seconds_total{method="getLogs"} 1.5`)
  })
})

describe("Metrics.collect", () => {
  it("Renders only the indexer info when there is no state", t => {
    t.expect(Metrics.collect(~metrics=None)).toBe(`# HELP envio_info Information about the indexer
# TYPE envio_info gauge
envio_info{version="${Utils.EnvioPackage.value.version}"} 1
`)
  })

  it("Escapes both the effect and the scope label values", t => {
    let metrics: Metrics.t = {
      startTime: Date.fromTime(0.),
      targetBufferSize: 0,
      isInReorgThreshold: false,
      rollbackEnabled: false,
      maxBatchSize: 0,
      preloadSeconds: 0.,
      processingSeconds: 0.,
      rollbackSeconds: 0.,
      rollbackCount: 0,
      rollbackEventsCount: 0.,
      chains: [],
      handlers: [],
      effects: [
        {
          effect: `a"b`,
          scope: `c"d`,
          callSeconds: 0.,
          callSecondsTotal: 0.,
          callCount: 2.,
          activeCallsCount: 0,
          queueCount: 0,
          queueWaitSeconds: 0.,
          invalidationsCount: 0.,
          cacheCount: None,
        },
      ],
      storageLoads: [],
      storageWrites: [],
      historyPrunes: [],
      sourceRequests: [],
      sourceHeights: [],
    }

    t.expect(
      Metrics.collect(~metrics=Some(metrics))->String.includes(
        `envio_effect_call_total{effect="a\\"b",scope="c\\"d"} 2`,
      ),
    ).toBe(true)
  })
})
