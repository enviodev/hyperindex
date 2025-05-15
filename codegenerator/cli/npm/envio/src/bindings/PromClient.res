/** All metric types have two mandatory parameters: name and help. Refer to https://prometheus.io/docs/practices/naming/ for guidance on naming metrics. */
type customMetric<'a> = {.."name": string, "help": string} as 'a

@module("prom-client") external collectDefaultMetrics: 'a => unit = "collectDefaultMetrics"

type registry
@new @module("prom-client") external makeRegistry: unit => registry = "Registry"

@module("prom-client") external defaultRegister: registry = "register"

@send external metrics: registry => Promise.t<string> = "metrics"
@get external getContentType: registry => string = "contentType"

module Counter = {
  type counter
  @new @module("prom-client") external makeCounter: customMetric<'a> => counter = "Counter"

  @send external inc: counter => unit = "inc"
  @send external incMany: (counter, int) => unit = "inc"

  @send external labels: (counter, 'labelsObject) => counter = "labels"
}

module Gauge = {
  type gauge
  @new @module("prom-client") external makeGauge: customMetric<'a> => gauge = "Gauge"

  @send external inc: gauge => unit = "inc"
  @send external incMany: (gauge, int) => unit = "inc"

  @send external dec: gauge => unit = "dec"
  @send external decMany: (gauge, int) => unit = "dec"

  @send external set: (gauge, int) => unit = "set"

  @send external setFloat: (gauge, float) => unit = "set"

  @send external labels: (gauge, 'labelsObject) => gauge = "labels"
}

module Histogram = {
  type histogram
  @new @module("prom-client") external make: customMetric<'a> => histogram = "Histogram"

  @send external observe: (histogram, float) => unit = "observe"
  @send external startTimer: histogram => unit => unit = "startTimer"

  @send external labels: (histogram, 'labelsObject) => histogram = "labels"
}

module Summary = {
  type summary
  @new @module("prom-client") external makeSummary: customMetric<'a> => summary = "Summary"

  @send external observe: (summary, float) => unit = "observe"
  @send external startTimer: (summary, unit) => float = "startTimer"
}
