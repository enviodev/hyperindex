let loadEntitiesDurationCounter = PromClient.Counter.makeCounter({
  "name": "load_entities_processing_time_spent",
  "help": "Duration spend on loading entities",
  "labelNames": [],
})

let eventRouterDurationCounter = PromClient.Counter.makeCounter({
  "name": "event_router_processing_time_spent",
  "help": "Duration spend on event routing",
  "labelNames": [],
})

let executeBatchDurationCounter = PromClient.Counter.makeCounter({
  "name": "execute_batch_processing_time_spent",
  "help": "Duration spend on executing batch",
  "labelNames": [],
})

let eventsProcessedCounter = PromClient.Counter.makeCounter({
  "name": "events_processed",
  "help": "Total number of events processed",
  "labelNames": [],
})

let reorgsDetectedCounter = PromClient.Counter.makeCounter({
  "name": "reorgs_detected",
  "help": "Total number of reorgs detected",
  "labelNames": ["chainId"],
})

let allChainsSyncedToHead = PromClient.Gauge.makeGauge({
  "name": "hyperindex_synced_to_head",
  "help": "All chains fully synced",
  "labelNames": [],
})

let sourceChainHeight = PromClient.Gauge.makeGauge({
  "name": "chain_block_height",
  "help": "Chain Height of Source Chain",
  "labelNames": ["chainId"],
})

let benchmarkSummaryData = PromClient.Gauge.makeGauge({
  "name": "benchmark_summary_data",
  "help": "All data points collected during indexer benchmark",
  "labelNames": ["group", "label", "stat"],
})

let setBenchmarkSummaryData = (
  ~group: string,
  ~label: string,
  ~n: int,
  ~mean: float,
  ~stdDev: option<float>,
  ~min: float,
  ~max: float,
  ~sum: float,
) => {
  benchmarkSummaryData
  ->PromClient.Gauge.labels({"group": group, "label": label, "stat": "n"})
  ->PromClient.Gauge.set(n)

  benchmarkSummaryData
  ->PromClient.Gauge.labels({"group": group, "label": label, "stat": "mean"})
  ->PromClient.Gauge.setFloat(mean)

  switch stdDev {
  | Some(stdDev) =>
    benchmarkSummaryData
    ->PromClient.Gauge.labels({"group": group, "label": label, "stat": "stdDev"})
    ->PromClient.Gauge.setFloat(stdDev)
  | None => ()
  }

  benchmarkSummaryData
  ->PromClient.Gauge.labels({"group": group, "label": label, "stat": "min"})
  ->PromClient.Gauge.setFloat(min)

  benchmarkSummaryData
  ->PromClient.Gauge.labels({"group": group, "label": label, "stat": "max"})
  ->PromClient.Gauge.setFloat(max)

  benchmarkSummaryData
  ->PromClient.Gauge.labels({"group": group, "label": label, "stat": "sum"})
  ->PromClient.Gauge.setFloat(sum)
}

// TODO: implement this metric that updates in batches, currently unused
let processedUntilHeight = PromClient.Gauge.makeGauge({
  "name": "chain_block_height_processed",
  "help": "Block height processed by indexer",
  "labelNames": ["chainId"],
})

let fetchedEventsUntilHeight = PromClient.Gauge.makeGauge({
  "name": "chain_fetcher_block_height_processed",
  "help": "Block height processed by indexer",
  "labelNames": ["chainId"],
})

let incrementLoadEntityDurationCounter = (~duration) => {
  loadEntitiesDurationCounter->PromClient.Counter.incMany(duration)
}

let incrementEventRouterDurationCounter = (~duration) => {
  eventRouterDurationCounter->PromClient.Counter.incMany(duration)
}

let incrementExecuteBatchDurationCounter = (~duration) => {
  executeBatchDurationCounter->PromClient.Counter.incMany(duration)
}

let incrementEventsProcessedCounter = (~number) => {
  eventsProcessedCounter->PromClient.Counter.incMany(number)
}

let incrementReorgsDetected = (~chain) => {
  reorgsDetectedCounter->PromClient.Counter.incLabels({"chainId": chain->ChainMap.Chain.toString})
}

let setSourceChainHeight = (~blockNumber, ~chain) => {
  sourceChainHeight
  ->PromClient.Gauge.labels({"chainId": chain->ChainMap.Chain.toString})
  ->PromClient.Gauge.set(blockNumber)
}

let setAllChainsSyncedToHead = () => {
  allChainsSyncedToHead->PromClient.Gauge.set(1)
}

let setProcessedUntilHeight = (~blockNumber, ~chain) => {
  processedUntilHeight
  ->PromClient.Gauge.labels({"chainId": chain->ChainMap.Chain.toString})
  ->PromClient.Gauge.set(blockNumber)
}

let setFetchedEventsUntilHeight = (~blockNumber, ~chain) => {
  processedUntilHeight
  ->PromClient.Gauge.labels({"chainId": chain->ChainMap.Chain.toString})
  ->PromClient.Gauge.set(blockNumber)
}
