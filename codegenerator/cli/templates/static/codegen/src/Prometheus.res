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

let sourceChainHeight = PromClient.Gauge.makeGauge({
  "name": "chain_block_height",
  "help": "Chain Height of Source Chain",
  "labelNames": ["chainId"],
})

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

let setSourceChainHeight = (~blockNumber, ~chain) => {
  sourceChainHeight
  ->PromClient.Gauge.labels({"chainId": chain->ChainMap.Chain.toString})
  ->PromClient.Gauge.set(blockNumber)
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
