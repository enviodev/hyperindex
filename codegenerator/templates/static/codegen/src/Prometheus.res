let eventProcessedCounter = PromClient.Counter.makeCounter({
  "name": "automation_service_number_event_processed_counter",
  "help": "Number of events that have been processed by the indexer",
  "labelNames": ["chainId"],
})

let eventRouterProcessingTimeSpent = PromClient.Counter.makeCounter({
  "name": "event_router_processing_time_spent",
  "help": "Number of events that have been processed by the indexer",
  "labelNames": [],
})

let incrementEventProcessedCounter = (~chainId) => {
  eventProcessedCounter
  ->PromClient.Counter.labels({
    "chainId": chainId,
  })
  ->PromClient.Counter.inc
}

let incrementEventRouterProcessingTimeSpent = (~amount) => {
  eventRouterProcessingTimeSpent
  ->PromClient.Counter.incMany(amount)
}


