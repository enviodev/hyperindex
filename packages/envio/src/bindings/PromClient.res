/** All metric types have two mandatory parameters: name and help. Refer to https://prometheus.io/docs/practices/naming/ for guidance on naming metrics. */
type customMetric<'a> = {.."name": string, "help": string} as 'a

@module("prom-client") external collectDefaultMetrics: 'a => unit = "collectDefaultMetrics"

type registry
@new @module("prom-client") external makeRegistry: unit => registry = "Registry"

@module("prom-client") external defaultRegister: registry = "register"

@send external metrics: registry => Promise.t<string> = "metrics"
@get external getContentType: registry => string = "contentType"

type metricValue = {
  value: int,
  labels: dict<string>,
}
type metricInstance = {get: unit => promise<{"values": array<metricValue>}>}
@send external getSingleMetric: (registry, string) => option<metricInstance> = "getSingleMetric"
@send external resetMetrics: registry => unit = "resetMetrics"
@send external clear: registry => unit = "clear"

// Idempotent metric creation: if the metric already exists in the
// registry (e.g., module loaded twice via different pnpm paths),
// return the existing one instead of throwing.
let getOrCreate = (name: string, create: unit => 'a): 'a => {
  switch defaultRegister->getSingleMetric(name) {
  | Some(existing) => existing->(Utils.magic: metricInstance => 'a)
  | None => create()
  }
}

module Counter = {
  type counter
  @new @module("prom-client") external makeCounterUnsafe: customMetric<'a> => counter = "Counter"
  let makeCounter = (config: customMetric<'a>): counter =>
    getOrCreate(config["name"], () => makeCounterUnsafe(config))

  @send external inc: counter => unit = "inc"
  @send external incMany: (counter, int) => unit = "inc"

  @send external labels: (counter, 'labelsObject) => counter = "labels"
}

module Gauge = {
  type gauge
  @new @module("prom-client") external makeGaugeUnsafe: customMetric<'a> => gauge = "Gauge"
  let makeGauge = (config: customMetric<'a>): gauge =>
    getOrCreate(config["name"], () => makeGaugeUnsafe(config))

  @send external inc: gauge => unit = "inc"
  @send external incMany: (gauge, int) => unit = "inc"

  @send external dec: gauge => unit = "dec"
  @send external decMany: (gauge, int) => unit = "dec"

  @send external set: (gauge, int) => unit = "set"

  @send external setFloat: (gauge, float) => unit = "set"

  @send external labels: (gauge, 'labelsObject) => gauge = "labels"

  @send external get: gauge => promise<{"values": array<dict<string>>}> = "get"
}

module Summary = {
  type summary
  @new @module("prom-client") external makeSummary: customMetric<'a> => summary = "Summary"

  @send external observe: (summary, float) => unit = "observe"
  @send external startTimer: (summary, unit) => float = "startTimer"
}
