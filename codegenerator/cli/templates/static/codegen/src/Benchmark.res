module MillisAccum = {
  type millis = int
  type t = {counters: dict<millis>, startTime: Js.Date.t, mutable endTime: Js.Date.t}
  let schema: S.t<t> = S.schema(s => {
    counters: s.matches(S.dict(S.int)),
    startTime: s.matches(S.string->S.datetime),
    endTime: s.matches(S.string->S.datetime),
  })
  let make: unit => t = () => {
    counters: Js.Dict.empty(),
    startTime: Js.Date.make(),
    endTime: Js.Date.make(),
  }

  let increment = (self: t, label, amount) => {
    switch self.counters->Utils.Dict.dangerouslyGetNonOption(label) {
    | None => self.counters->Js.Dict.set(label, amount)
    | Some(current) => self.counters->Js.Dict.set(label, current + amount)
    }
    self.endTime = Js.Date.make()
  }
}

module SummaryData = {
  module DataSet = {
    type t = {
      count: int,
      min: float,
      max: float,
      sum: BigDecimal.t,
      sumOfSquares: BigDecimal.t,
      decimalPlaces: int,
    }

    let schema = S.schema(s => {
      count: s.matches(S.int),
      min: s.matches(S.float),
      max: s.matches(S.float),
      sum: s.matches(BigDecimal.schema),
      sumOfSquares: s.matches(BigDecimal.schema),
      decimalPlaces: s.matches(S.int),
    })

    let make = (val: float, ~decimalPlaces=2) => {
      let bigDecimal = val->BigDecimal.fromFloat
      {
        count: 1,
        min: val,
        max: val,
        sum: bigDecimal,
        sumOfSquares: bigDecimal->BigDecimal.times(bigDecimal),
        decimalPlaces,
      }
    }

    let add = (self: t, val: float) => {
      let bigDecimal = val->BigDecimal.fromFloat
      {
        count: self.count + 1,
        min: Pervasives.min(self.min, val),
        max: Pervasives.max(self.max, val),
        sum: self.sum->BigDecimal.plus(bigDecimal),
        sumOfSquares: self.sumOfSquares->BigDecimal.plus(bigDecimal->BigDecimal.times(bigDecimal)),
        decimalPlaces: self.decimalPlaces,
      }
    }
  }
  module Group = {
    type t = dict<DataSet.t>
    let schema: S.t<t> = S.dict(DataSet.schema)
    let make = () => Js.Dict.empty()

    let add = (self: t, key: string, value: float, ~decimalPlaces=2) => {
      switch self->Utils.Dict.dangerouslyGetNonOption(key) {
      | None => self->Js.Dict.set(key, DataSet.make(value, ~decimalPlaces))
      | Some(dataSet) => self->Js.Dict.set(key, dataSet->DataSet.add(value))
      }
    }
  }

  type t = dict<Group.t>
  let schema = S.dict(Group.schema)
  let make = () => Js.Dict.empty()

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

  let incrementMillis = (self: t, ~label, ~amount) => {
    self.millisAccum->MillisAccum.increment(label, amount)
  }

  let addSummaryData = (self: t, ~group, ~label, ~value, ~decimalPlaces=2) => {
    self.summaryData->SummaryData.add(~group, ~label, ~value, ~decimalPlaces)
  }
}

let data = Data.make()
let throttler = Throttler.make(
  ~intervalMillis=500,
  ~logger=Logging.createChild(~params={"context": "Benchmarking framework"}),
)
let cacheFileName = "BenchmarkCache.json"
let cacheFilePath = NodeJsLocal.Path.join(NodeJsLocal.Path.__dirname, cacheFileName)

let saveToCacheFile = data => {
  let write = () => {
    let json = data->S.serializeToJsonStringOrRaiseWith(Data.schema)
    NodeJsLocal.Fs.Promises.writeFile(~filepath=cacheFilePath, ~content=json)
  }
  throttler->Throttler.schedule(write)
}

let readFromCacheFile = async () => {
  switch await NodeJsLocal.Fs.Promises.readFile(~filepath=cacheFilePath, ~encoding=Utf8) {
  | exception _ => None
  | content =>
    switch content->S.parseJsonStringWith(Data.schema) {
    | Ok(data) => Some(data)
    | Error(e) =>
      Logging.error(
        "Failed to parse benchmark cache file, please delete it and rerun the benchmark",
      )
      e->S.Error.raise
    }
  }
}

let addSummaryData = (~group, ~label, ~value, ~decimalPlaces=2) => {
  data->Data.addSummaryData(~group, ~label, ~value, ~decimalPlaces)
  data->saveToCacheFile
}

let incrementMillis = (~label, ~amount) => {
  data->Data.incrementMillis(~label, ~amount)
  data->saveToCacheFile
}

let addBlockRangeFetched = (
  ~totalTimeElapsed: int,
  ~parsingTimeElapsed: int,
  ~pageFetchTime: int,
  ~chainId,
  ~fromBlock,
  ~toBlock,
  ~fetchStateRegisterId: FetchState.id,
  ~numEvents,
  ~partitionId,
) => {
  let registerName = switch fetchStateRegisterId {
  | Root => "Root"
  | DynamicContract(_) => "Dynamic Contract"
  }

  let group = `BlockRangeFetched Summary for Chain ${chainId->Belt.Int.toString} ${registerName} Register`
  let add = (label, value) => data->Data.addSummaryData(~group, ~label, ~value=Utils.magic(value))

  add("Total Time Elapsed (ms)", totalTimeElapsed)
  add("Parsing Time Elapsed (ms)", parsingTimeElapsed)
  add("Page Fetch Time (ms)", pageFetchTime)
  add("Num Events", numEvents)
  add("Block Range Size", toBlock - fromBlock)

  data->Data.incrementMillis(
    ~label=`Total Time Fetching Chain ${chainId->Belt.Int.toString} Partition ${partitionId->Belt.Int.toString}`,
    ~amount=totalTimeElapsed,
  )

  data->saveToCacheFile
}

let eventProcessingGroup = "EventProcessing Summary"
let batchSizeLabel = "Batch Size"

let addEventProcessing = (
  ~batchSize,
  ~contractRegisterDuration,
  ~loadDuration,
  ~handlerDuration,
  ~dbWriteDuration,
  ~totalTimeElapsed,
) => {
  let add = (label, value) =>
    data->Data.addSummaryData(~group=eventProcessingGroup, ~label, ~value=value->Belt.Int.toFloat)

  add(batchSizeLabel, batchSize)
  add("Contract Register Duration (ms)", contractRegisterDuration)
  add("Load Duration (ms)", loadDuration)
  add("Handler Duration (ms)", handlerDuration)
  add("DB Write Duration (ms)", dbWriteDuration)
  add("Total Time Elapsed (ms)", totalTimeElapsed)

  data->Data.incrementMillis(~label="Total Time Processing", ~amount=totalTimeElapsed)

  data->saveToCacheFile
}

module Summary = {
  open Belt
  type t = {
    n: int,
    mean: float,
    @as("std-dev") stdDev: float,
    min: float,
    max: float,
    sum: float,
  }

  type summaryTable = dict<t>

  external logSummaryTable: summaryTable => unit = "console.table"
  external logArrTable: array<'a> => unit = "console.table"
  external logObjTable: {..} => unit = "console.table"
  external logDictTable: dict<'a> => unit = "console.table"

  external arrayIntToFloat: array<int> => array<float> = "%identity"

  let round = (float, ~precision=2) => {
    let factor = Js.Math.pow_float(~base=10.0, ~exp=precision->Int.toFloat)
    Js.Math.round(float *. factor) /. factor
  }

  let makeFromDataSet = (dataSet: SummaryData.DataSet.t) => {
    let n = dataSet.count
    let countBigDecimal = n->BigDecimal.fromInt
    let mean = dataSet.sum->BigDecimal.div(countBigDecimal)
    let variance =
      dataSet.sumOfSquares
      ->BigDecimal.div(countBigDecimal)
      ->BigDecimal.minus(mean->BigDecimal.times(mean))
    let stdDev = BigDecimal.sqrt(variance)
    let roundBigDecimal = bd =>
      bd->BigDecimal.decimalPlaces(dataSet.decimalPlaces)->BigDecimal.toNumber
    let roundFloat = float => float->round(~precision=dataSet.decimalPlaces)
    {
      n,
      mean: mean->roundBigDecimal,
      stdDev: stdDev->roundBigDecimal,
      min: dataSet.min->roundFloat,
      max: dataSet.max->roundFloat,
      sum: dataSet.sum->roundBigDecimal,
    }
  }

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
        timeBreakdown->Js.Array2.push((label, DateFns.durationFromMillis(millis)))->ignore
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
        ->Array.map(((label, values)) => (label, values->makeFromDataSet))
        ->Js.Dict.fromArray
        ->logDictTable
      })
    }
  }
}
