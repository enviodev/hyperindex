module MillisAccum = {
  type millis = float
  type t = {counters: dict<millis>, startTime: Js.Date.t, mutable endTime: Js.Date.t}
  let schema: S.t<t> = S.schema(s => {
    counters: s.matches(S.dict(S.float)),
    startTime: s.matches(S.string->S.datetime),
    endTime: s.matches(S.string->S.datetime),
  })
  let make: unit => t = () => {
    counters: Js.Dict.empty(),
    startTime: Js.Date.make(),
    endTime: Js.Date.make(),
  }

  let increment = (self: t, label, amount) => {
    self.endTime = Js.Date.make()
    let amount = amount->Belt.Float.fromInt
    switch self.counters->Utils.Dict.dangerouslyGetNonOption(label) {
    | None =>
      self.counters->Js.Dict.set(label, amount)
      amount
    | Some(current) =>
      let newAmount = current +. amount
      self.counters->Js.Dict.set(label, newAmount)
      newAmount
    }
  }
}

module SummaryData = {
  module DataSet = {
    type t = {
      count: float,
      min: float,
      max: float,
      sum: BigDecimal.t,
      sumOfSquares: option<BigDecimal.t>,
      decimalPlaces: int,
    }

    let schema = S.schema(s => {
      count: s.matches(S.float),
      min: s.matches(S.float),
      max: s.matches(S.float),
      sum: s.matches(BigDecimal.schema),
      sumOfSquares: s.matches(S.option(BigDecimal.schema)),
      decimalPlaces: s.matches(S.int),
    })

    let make = (val: float, ~decimalPlaces=2) => {
      let bigDecimal = val->BigDecimal.fromFloat
      {
        count: 1.,
        min: val,
        max: val,
        sum: bigDecimal,
        sumOfSquares: Env.Benchmark.shouldSaveStdDev
          ? Some(bigDecimal->BigDecimal.times(bigDecimal))
          : None,
        decimalPlaces,
      }
    }

    let add = (self: t, val: float) => {
      let bigDecimal = val->BigDecimal.fromFloat
      {
        count: self.count +. 1.,
        min: Pervasives.min(self.min, val),
        max: Pervasives.max(self.max, val),
        sum: self.sum->BigDecimal.plus(bigDecimal),
        sumOfSquares: self.sumOfSquares->Belt.Option.map(s =>
          s->BigDecimal.plus(bigDecimal->BigDecimal.times(bigDecimal))
        ),
        decimalPlaces: self.decimalPlaces,
      }
    }
  }
  module Group = {
    type t = dict<DataSet.t>
    let schema: S.t<t> = S.dict(DataSet.schema)
    let make = (): t => Js.Dict.empty()

    /**
    Adds a value to the data set for the given key. If the key does not exist, it will be created.

    Returns the updated data set.
    */
    let add = (self: t, label, value: float, ~decimalPlaces=2) => {
      switch self->Utils.Dict.dangerouslyGetNonOption(label) {
      | None =>
        let new = DataSet.make(value, ~decimalPlaces)
        self->Js.Dict.set(label, new)
        new
      | Some(dataSet) =>
        let updated = dataSet->DataSet.add(value)
        self->Js.Dict.set(label, updated)
        updated
      }
    }
  }

  type t = dict<Group.t>
  let schema = S.dict(Group.schema)
  let make = (): t => Js.Dict.empty()

  let add = (self: t, ~group, ~label, ~value, ~decimalPlaces=2) => {
    let group = switch self->Utils.Dict.dangerouslyGetNonOption(group) {
    | None =>
      let newGroup = Group.make()
      self->Js.Dict.set(group, newGroup)
      newGroup
    | Some(group) => group
    }

    group->Group.add(label, value, ~decimalPlaces)
  }
}

module Stats = {
  open Belt
  type t = {
    n: float,
    mean: float,
    @as("std-dev") stdDev: option<float>,
    min: float,
    max: float,
    sum: float,
  }

  let round = (float, ~precision=2) => {
    let factor = Js.Math.pow_float(~base=10.0, ~exp=precision->Int.toFloat)
    Js.Math.round(float *. factor) /. factor
  }

  let makeFromDataSet = (dataSet: SummaryData.DataSet.t) => {
    let n = dataSet.count
    let countBigDecimal = n->BigDecimal.fromFloat
    let mean = dataSet.sum->BigDecimal.div(countBigDecimal)

    let roundBigDecimal = bd =>
      bd->BigDecimal.decimalPlaces(dataSet.decimalPlaces)->BigDecimal.toNumber
    let roundFloat = float => float->round(~precision=dataSet.decimalPlaces)

    let stdDev = dataSet.sumOfSquares->Option.map(sumOfSquares => {
      let variance =
        sumOfSquares
        ->BigDecimal.div(countBigDecimal)
        ->BigDecimal.minus(mean->BigDecimal.times(mean))
      BigDecimal.sqrt(variance)->roundBigDecimal
    })
    {
      n,
      mean: mean->roundBigDecimal,
      stdDev,
      min: dataSet.min->roundFloat,
      max: dataSet.max->roundFloat,
      sum: dataSet.sum->roundBigDecimal,
    }
  }
}

module Data = {
  type t = {
    millisAccum: MillisAccum.t,
    summaryData: SummaryData.t,
  }

  let schema = S.schema(s => {
    millisAccum: s.matches(MillisAccum.schema),
    summaryData: s.matches(SummaryData.schema),
  })

  let make = () => {
    millisAccum: MillisAccum.make(),
    summaryData: SummaryData.make(),
  }

  module LiveMetrics = {
    let addDataSet = if (
      Env.Benchmark.saveDataStrategy->Env.Benchmark.SaveDataStrategy.shouldSavePrometheus
    ) {
      (dataSet: SummaryData.DataSet.t, ~group, ~label) => {
        let {n, mean, stdDev, min, max, sum} = dataSet->Stats.makeFromDataSet
        Prometheus.BenchmarkSummaryData.set(~group, ~label, ~n, ~mean, ~stdDev, ~min, ~max, ~sum)
      }
    } else {
      (_dataSet, ~group as _, ~label as _) => ()
    }
    let setCounterMillis = if (
      Env.Benchmark.saveDataStrategy->Env.Benchmark.SaveDataStrategy.shouldSavePrometheus
    ) {
      (millisAccum: MillisAccum.t, ~label, ~millis) => {
        let totalRuntimeMillis =
          millisAccum.endTime->Js.Date.getTime -. millisAccum.startTime->Js.Date.getTime
        Prometheus.BenchmarkCounters.set(~label, ~millis, ~totalRuntimeMillis)
      }
    } else {
      (_, ~label as _, ~millis as _) => ()
    }
  }

  let incrementMillis = (self: t, ~label, ~amount) => {
    let nextMillis = self.millisAccum->MillisAccum.increment(label, amount)
    self.millisAccum->LiveMetrics.setCounterMillis(~label, ~millis=nextMillis)
  }

  let addSummaryData = (self: t, ~group, ~label, ~value, ~decimalPlaces=2) => {
    let updatedDataSet = self.summaryData->SummaryData.add(~group, ~label, ~value, ~decimalPlaces)
    updatedDataSet->LiveMetrics.addDataSet(~group, ~label)
  }
}

let data = Data.make()
let throttler = Throttler.make(
  ~intervalMillis=Env.ThrottleWrites.jsonFileBenchmarkIntervalMillis,
  ~logger=Logging.createChild(~params={"context": "Benchmarking framework"}),
)
let cacheFileName = "BenchmarkCache.json"
let cacheFilePath = NodeJs.Path.join(NodeJs.Path.__dirname, cacheFileName)

let saveToCacheFile = if (
  Env.Benchmark.saveDataStrategy->Env.Benchmark.SaveDataStrategy.shouldSaveJsonFile
) {
  //Save to cache file only happens if the strategy is set to json-file
  data => {
    let write = () => {
      let json = data->S.reverseConvertToJsonStringOrThrow(Data.schema)
      NodeJs.Fs.Promises.writeFile(~filepath=cacheFilePath, ~content=json)
    }
    throttler->Throttler.schedule(write)
  }
} else {
  _ => ()
}

let readFromCacheFile = async () => {
  switch await NodeJs.Fs.Promises.readFile(~filepath=cacheFilePath, ~encoding=Utf8) {
  | exception _ => None
  | content =>
    try content->S.parseJsonStringOrThrow(Data.schema)->Some catch {
    | S.Raised(e) =>
      Logging.error(
        "Failed to parse benchmark cache file, please delete it and rerun the benchmark",
      )
      e->S.Error.raise
    }
  }
}

let addSummaryData = (~group, ~label, ~value, ~decimalPlaces=2) => {
  let _ = data->Data.addSummaryData(~group, ~label, ~value, ~decimalPlaces)
  data->saveToCacheFile
}

let incrementMillis = (~label, ~amount) => {
  let _ = data->Data.incrementMillis(~label, ~amount)
  data->saveToCacheFile
}

let addBlockRangeFetched = (
  ~totalTimeElapsed: int,
  ~parsingTimeElapsed: int,
  ~pageFetchTime: int,
  ~chainId,
  ~fromBlock,
  ~toBlock,
  ~numEvents,
  ~numAddresses,
  ~queryName,
) => {
  let group = `BlockRangeFetched Summary for Chain ${chainId->Belt.Int.toString} ${queryName}`
  let add = (label, value) => data->Data.addSummaryData(~group, ~label, ~value=Utils.magic(value))

  add("Total Time Elapsed (ms)", totalTimeElapsed)
  add("Parsing Time Elapsed (ms)", parsingTimeElapsed)
  add("Page Fetch Time (ms)", pageFetchTime)
  add("Num Events", numEvents)
  add("Num Addresses", numAddresses)
  add("Block Range Size", toBlock - fromBlock)

  data->Data.incrementMillis(
    ~label=`Total Time Fetching Chain ${chainId->Belt.Int.toString} ${queryName}`,
    ~amount=totalTimeElapsed,
  )

  data->saveToCacheFile
}

let eventProcessingGroup = "EventProcessing Summary"
let batchSizeLabel = "Batch Size"

let addEventProcessing = (
  ~batchSize,
  ~loadDuration,
  ~handlerDuration,
  ~dbWriteDuration,
  ~totalTimeElapsed,
) => {
  let add = (label, value) =>
    data->Data.addSummaryData(~group=eventProcessingGroup, ~label, ~value=value->Belt.Int.toFloat)

  add(batchSizeLabel, batchSize)
  add("Load Duration (ms)", loadDuration)
  add("Handler Duration (ms)", handlerDuration)
  add("DB Write Duration (ms)", dbWriteDuration)
  add("Total Time Elapsed (ms)", totalTimeElapsed)

  data->Data.incrementMillis(~label="Total Time Processing", ~amount=totalTimeElapsed)

  data->saveToCacheFile
}

module Summary = {
  open Belt

  type summaryTable = dict<Stats.t>

  external logSummaryTable: summaryTable => unit = "console.table"
  external logArrTable: array<'a> => unit = "console.table"
  external logObjTable: {..} => unit = "console.table"
  external logDictTable: dict<'a> => unit = "console.table"

  external arrayIntToFloat: array<int> => array<float> = "%identity"

  let printSummary = async () => {
    let data = await readFromCacheFile()
    switch data {
    | None =>
      Logging.error(
        "No benchmark cache file found, please use 'ENVIO_SAVE_BENCHMARK_DATA=true' and rerun the benchmark",
      )
    | Some({summaryData, millisAccum}) =>
      Js.log("Time breakdown")
      let timeBreakdown = [
        (
          "Total Runtime",
          DateFns.intervalToDuration({
            start: millisAccum.startTime,
            end: millisAccum.endTime,
          }),
        ),
      ]

      millisAccum.counters
      ->Js.Dict.entries
      ->Array.forEach(((label, millis)) =>
        timeBreakdown
        ->Js.Array2.push((label, DateFns.durationFromMillis(millis->Belt.Int.fromFloat)))
        ->ignore
      )

      timeBreakdown
      ->Js.Dict.fromArray
      ->logDictTable

      Js.log("General")
      let batchSizesSum =
        summaryData
        ->Js.Dict.get(eventProcessingGroup)
        ->Option.flatMap(g => g->Js.Dict.get(batchSizeLabel))
        ->Option.map(data => data.sum)
        ->Option.getWithDefault(BigDecimal.zero)

      let totalRuntimeMillis =
        millisAccum.endTime->Js.Date.getTime -. millisAccum.startTime->Js.Date.getTime

      let totalRuntimeSeconds = totalRuntimeMillis /. 1000.

      let eventsPerSecond =
        batchSizesSum
        ->BigDecimal.div(BigDecimal.fromFloat(totalRuntimeSeconds))
        ->BigDecimal.decimalPlaces(2)
        ->BigDecimal.toNumber

      logObjTable({
        "batch sizes sum": batchSizesSum->BigDecimal.toNumber,
        "total runtime (sec)": totalRuntimeSeconds,
        "events per second": eventsPerSecond,
      })

      summaryData
      ->Js.Dict.entries
      ->Js.Array2.sortInPlaceWith(((a, _), (b, _)) => a < b ? -1 : 1)
      ->Array.forEach(((groupName, group)) => {
        Js.log(groupName)
        group
        ->Js.Dict.entries
        ->Array.map(((label, values)) => (label, values->Stats.makeFromDataSet))
        ->Js.Dict.fromArray
        ->logDictTable
      })
    }
  }
}
