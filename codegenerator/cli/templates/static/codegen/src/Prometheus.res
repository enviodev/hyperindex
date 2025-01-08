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

module Labels = {
  let rec schemaIsString = (schema: S.t<'a>) =>
    switch schema->S.classify {
    | String => true
    | Null(s)
    | Option(s) =>
      s->schemaIsString
    | _ => false
    }

  let getLabelNames = (schema: S.t<'a>) =>
    switch schema->S.classify {
    | Object({items}) =>
      let nonStringFields = items->Belt.Array.reduce([], (nonStringFields, item) => {
        if item.schema->schemaIsString {
          nonStringFields
        } else {
          nonStringFields->Belt.Array.concat([item.location])
        }
      })

      switch nonStringFields {
      | [] => items->Belt.Array.map(item => item.location)->Ok
      | nonStringItems =>
        let nonStringItems = nonStringItems->Js.Array2.joinWith(", ")
        Error(
          `Label schema must be an object with string (or optional string) values. Non string values: ${nonStringItems}`,
        )
      }
    | _ => Error("Label schema must be an object")
    }
}

let metricNames: Utils.Set.t<string> = Utils.Set.make()

module MakeSafePromMetric = (
  M: {
    type t
    let make: {"name": string, "help": string, "labelNames": array<string>} => t
    let labels: (t, 'a) => t
    let handleFloat: (t, float) => unit
    let handleInt: (t, int) => unit
  },
): {
  type t<'a>
  let makeOrThrow: (~name: string, ~help: string, ~labelSchema: S.t<'a>) => t<'a>
  let handleInt: (t<'a>, ~labels: 'a, ~value: int) => unit
  let handleFloat: (t<'a>, ~labels: 'a, ~value: float) => unit
} => {
  type t<'a> = {metric: M.t, labelSchema: S.t<'a>}

  let makeOrThrow = (~name, ~help, ~labelSchema: S.t<'a>): t<'a> =>
    switch labelSchema->Labels.getLabelNames {
    | Ok(labelNames) =>
      if metricNames->Utils.Set.has(name) {
        Js.Exn.raiseError("Duplicate prometheus metric name: " ++ name)
      } else {
        metricNames->Utils.Set.add(name)->ignore
        let metric = M.make({
          "name": name,
          "help": help,
          "labelNames": labelNames,
        })

        {metric, labelSchema}
      }

    | Error(error) => Js.Exn.raiseError(error)
    }

  let handleFloat = ({metric, labelSchema}: t<'a>, ~labels: 'a, ~value) =>
    metric
    ->M.labels(labels->S.serializeOrRaiseWith(labelSchema))
    ->M.handleFloat(value)

  let handleInt = ({metric, labelSchema}: t<'a>, ~labels: 'a, ~value) =>
    metric
    ->M.labels(labels->S.serializeOrRaiseWith(labelSchema))
    ->M.handleInt(value)
}

module SafeCounter = MakeSafePromMetric({
  type t = PromClient.Counter.counter
  let make = PromClient.Counter.makeCounter
  let labels = PromClient.Counter.labels
  let handleInt = PromClient.Counter.incMany
  let handleFloat = PromClient.Counter.incMany->Utils.magic
})

module SafeGauge = MakeSafePromMetric({
  type t = PromClient.Gauge.gauge
  let make = PromClient.Gauge.makeGauge
  let labels = PromClient.Gauge.labels
  let handleInt = PromClient.Gauge.set
  let handleFloat = PromClient.Gauge.setFloat
})

module BenchmarkSummaryData = {
  type labels = {
    group: string,
    stat: string,
    label: string,
  }
  let labelSchema = S.schema(s => {
    group: s.matches(S.string),
    stat: s.matches(S.string),
    label: s.matches(S.string),
  })

  let gauge = SafeGauge.makeOrThrow(
    ~name="benchmark_summary_data",
    ~help="All data points collected during indexer benchmark",
    ~labelSchema,
  )

  let set = (
    ~group: string,
    ~label: string,
    ~n: float,
    ~mean: float,
    ~stdDev: option<float>,
    ~min: float,
    ~max: float,
    ~sum: float,
  ) => {
    let mk = stat => {
      group,
      stat,
      label,
    }
    gauge->SafeGauge.handleFloat(~labels=mk("n"), ~value=n)
    gauge->SafeGauge.handleFloat(~labels=mk("mean"), ~value=mean)
    gauge->SafeGauge.handleFloat(~labels=mk("min"), ~value=min)
    gauge->SafeGauge.handleFloat(~labels=mk("max"), ~value=max)
    gauge->SafeGauge.handleFloat(~labels=mk("sum"), ~value=sum)
    switch stdDev {
    | Some(stdDev) => gauge->SafeGauge.handleFloat(~labels=mk("stdDev"), ~value=stdDev)
    | None => ()
    }
  }
}

module BenchmarkCounters = {
  type labels = {label: string}
  let labelSchema = S.schema(s => {
    label: s.matches(S.string),
  })

  let gauge = SafeGauge.makeOrThrow(
    ~name="benchmark_counters",
    ~help="All counters collected during indexer benchmark",
    ~labelSchema,
  )

  let set = (~label, ~millis, ~totalRuntimeMillis) => {
    gauge->SafeGauge.handleFloat(~labels={label: label}, ~value=millis)
    gauge->SafeGauge.handleFloat(~labels={label: "Total Run Time (ms)"}, ~value=totalRuntimeMillis)
  }
}

module PartitionBlockFetched = {
  type labels = {chainId: int, partitionId: string}
  let intAsString = S.string->S.transform(s => {
    serializer: int => int->Belt.Int.toString,
    parser: string =>
      switch string->Belt.Int.fromString {
      | Some(int) => int
      | None => s.fail("The string is not valid int")
      },
  })

  let labelSchema = S.schema(s => {
    chainId: s.matches(intAsString),
    partitionId: s.matches(S.string),
  })

  let counter = SafeGauge.makeOrThrow(
    ~name="partition_block_fetched",
    ~help="The latest fetched block number for each partition",
    ~labelSchema,
  )

  let set = (~blockNumber, ~partitionId, ~chainId) => {
    counter->SafeGauge.handleInt(~labels={chainId, partitionId}, ~value=blockNumber)
  }
}

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
  fetchedEventsUntilHeight
  ->PromClient.Gauge.labels({"chainId": chain->ChainMap.Chain.toString})
  ->PromClient.Gauge.set(blockNumber)
}
