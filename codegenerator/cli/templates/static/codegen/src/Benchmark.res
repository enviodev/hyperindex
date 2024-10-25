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
      sum: float,
      sumOfSquares: float,
      decimalPlaces: int,
    }

    let schema = S.schema(s => {
      count: s.matches(S.int),
      min: s.matches(S.float),
      max: s.matches(S.float),
      sum: s.matches(S.float),
      sumOfSquares: s.matches(S.float),
      decimalPlaces: s.matches(S.int),
    })

    let make = (val: float, ~decimalPlaces=2) => {
      count: 1,
      min: val,
      max: val,
      sum: val,
      sumOfSquares: val *. val,
      decimalPlaces,
    }

    let add = (self: t, val: float) => {
      count: self.count + 1,
      min: Pervasives.min(self.min, val),
      max: Pervasives.max(self.max, val),
      sum: self.sum +. val,
      sumOfSquares: self.sumOfSquares +. val *. val,
      decimalPlaces: self.decimalPlaces,
    }
  }

  module Group = {
    type t = dict<DataSet.t>
    let schema: S.t<t> = S.dict(DataSet.schema)
    let make = () => Js.Dict.empty()

    let add = (self: t, key: string, value: float) => {
      switch self->Utils.Dict.dangerouslyGetNonOption(key) {
      | None => self->Js.Dict.set(key, DataSet.make(value))
      | Some(dataSet) => self->Js.Dict.set(key, dataSet->DataSet.add(value))
      }
    }
  }

  type t = dict<Group.t>
  let schema = S.dict(Group.schema)
  let make = () => Js.Dict.empty()

  let add = (self: t, ~group, ~label, ~value) => {
    let group = switch self->Utils.Dict.dangerouslyGetNonOption(group) {
    | None =>
      let newGroup = Group.make()
      self->Js.Dict.set(group, newGroup)
      newGroup
    | Some(group) => group
    }

    group->Group.add(label, value)
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

  let addSummaryData = (self: t, ~group, ~label, ~value) => {
    self.summaryData->SummaryData.add(~group, ~label, ~value)
  }
}

module LazyWriter = {
  let isWriting = ref(false)
  let scheduledWriteFn: ref<option<unit => promise<unit>>> = ref(None)
  let lastRunTimeMillis = ref(0.)

  let rec start = async () => {
    switch scheduledWriteFn.contents {
    | Some(fn) =>
      isWriting := true
      scheduledWriteFn := None
      lastRunTimeMillis := Js.Date.now()

      switch await fn() {
      | exception exn => Logging.errorWithExn(exn, "Failed to write benchmark cache file")
      | _ => ()
      }
      isWriting := false
      await start()
    | None => ()
    }
  }

  let schedule = (~intervalMillis=500, fn) => {
    scheduledWriteFn := Some(fn)
    if !isWriting.contents {
      let timeSinceLastRun = Js.Date.now() -. lastRunTimeMillis.contents
      if timeSinceLastRun >= intervalMillis->Belt.Int.toFloat {
        start()->ignore
      } else {
        let _ = Js.Global.setTimeout(() => {
          start()->ignore
        }, intervalMillis - timeSinceLastRun->Belt.Float.toInt)
      }
    }
  }
}

let data = Data.make()
let cacheFileName = "BenchmarkCache.json"
let cacheFilePath = NodeJsLocal.Path.join(NodeJsLocal.Path.__dirname, cacheFileName)

let saveToCacheFile = data => {
  let write = () => {
    let json = data->S.serializeToJsonStringOrRaiseWith(Data.schema)
    NodeJsLocal.Fs.Promises.writeFile(~filepath=cacheFilePath, ~content=json)
  }
  LazyWriter.schedule(write)
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

let addSummaryData = (~group, ~label, ~value) => {
  data->Data.addSummaryData(~group, ~label, ~value)
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
    let mean = dataSet.sum /. n->Int.toFloat
    let variance = dataSet.sumOfSquares /. n->Int.toFloat -. mean *. mean
    let stdDev = Js.Math.sqrt(variance)
    let precision = dataSet.decimalPlaces
    {
      n,
      mean: mean->round(~precision),
      stdDev: stdDev->round(~precision),
      min: dataSet.min->round(~precision),
      max: dataSet.max->round(~precision),
      sum: dataSet.sum->round(~precision),
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
        ->Option.getWithDefault(0.)

      let totalRuntimeMillis =
        millisAccum.endTime->Js.Date.getTime -. millisAccum.startTime->Js.Date.getTime

      let totalRuntimeSeconds = totalRuntimeMillis /. 1000.

      let eventsPerSecond = (batchSizesSum /. totalRuntimeSeconds)->round(~precision=2)

      logObjTable({
        "batch sizes sum": batchSizesSum,
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
