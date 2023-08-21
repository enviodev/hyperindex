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

let incrementLoadEntityDurationCounter = (~startTime, ~endTime) => {
  let duration = endTime - startTime
  loadEntitiesDurationCounter->PromClient.Counter.incMany(duration)
}

let incrementEventRouterDurationCounter = (~startTime, ~endTime) => {
  let duration = endTime - startTime
  eventRouterDurationCounter->PromClient.Counter.incMany(duration)
}

let incrementExecuteBatchDurationCounter = (~startTime, ~endTime) => {
  let duration = endTime - startTime
  executeBatchDurationCounter->PromClient.Counter.incMany(duration)
}
