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
  module Group = {
    type t = dict<array<float>>
    let schema = S.dict(S.array(S.float))
    let make = () => Js.Dict.empty()

    let add = (self: t, key: string, value: float) => {
      switch self->Utils.Dict.dangerouslyGetNonOption(key) {
      | None => self->Js.Dict.set(key, [value])
      | Some(arr) => arr->Js.Array2.push(value)->ignore
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

let data = Data.make()
let cacheFileName = "BenchmarkCache.json"
let cacheFilePath = NodeJsLocal.Path.join(NodeJsLocal.Path.__dirname, cacheFileName)

let saveToCacheFile = data => {
  let json = data->S.serializeToJsonStringOrRaiseWith(Data.schema)
  NodeJsLocal.Fs.Promises.writeFile(~filepath=cacheFilePath, ~content=json)->ignore
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
  ~stats: ChainWorker.blockRangeFetchStats,
  ~chainId,
  ~fromBlock,
  ~toBlock,
  ~fetchStateRegisterId: FetchState.id,
  ~numEvents,
) => {
  let registerName = switch fetchStateRegisterId {
  | Root => "Root"
  | DynamicContract(_) => "Dynamic Contract"
  }

  let group = `BlockRangeFetched Summary for Chain ${chainId->Belt.Int.toString} ${registerName} Register`
  let add = (label, value) => data->Data.addSummaryData(~group, ~label, ~value=Utils.magic(value))

  add("Total Time Elapsed (ms)", stats.totalTimeElapsed)
  add("Parsing Time Elapsed (ms)", stats.parsingTimeElapsed->Belt.Option.getWithDefault(0))
  add("Page Fetch Time (ms)", stats.pageFetchTime->Belt.Option.getWithDefault(0))
  add("Num Events", numEvents)
  add("Block Range Size", toBlock - fromBlock)

  data->Data.incrementMillis(
    ~label=`Total Time Fetching Chain ${chainId->Belt.Int.toString}`,
    ~amount=stats.totalTimeElapsed,
  )

  data->saveToCacheFile
}

let addEventProcessing = (
  ~batchSize,
  ~contractRegisterDuration,
  ~loadDuration,
  ~handlerDuration,
  ~dbWriteDuration,
  ~totalTimeElapsed,
) => {
  let add = (label, value) =>
    data->Data.addSummaryData(
      ~group="EventProcessing Summary",
      ~label,
      ~value=value->Belt.Int.toFloat,
    )

  add("Batch Size", batchSize)
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

  let make = (arr: array<float>) => {
    let div = (floatA, floatB) => floatA /. floatB
    let n = Array.length(arr)
    if n == 0 {
      {n, mean: 0., stdDev: 0., min: 0., max: 0.}
    } else {
      let nFloat = n->Int.toFloat
      let mean = arr->Array.reduce(0., (acc, time) => acc +. time)->div(nFloat)->round(~precision=2)
      let stdDev = {
        let variance =
          arr
          ->Array.reduce(0., (acc, val) => {
            let diff = val -. mean
            acc +. Js.Math.pow_float(~base=diff, ~exp=2.)
          })
          ->div(nFloat)

        variance->Js.Math.sqrt->round(~precision=2)
      }

      let min =
        arr
        ->Array.reduce(None, (acc, val) =>
          switch acc {
          | None => val
          | Some(acc) => Pervasives.min(acc, val)
          }
          ->round(~precision=2)
          ->Some
        )
        ->Option.getWithDefault(0.)
      let max =
        arr
        ->Array.reduce(None, (acc, val) =>
          switch acc {
          | None => val
          | Some(acc) => Pervasives.max(acc, val)
          }
          ->round(~precision=2)
          ->Some
        )
        ->Option.getWithDefault(0.)
      {n, mean, stdDev, min, max}
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

      summaryData
      ->Js.Dict.entries
      ->Js.Array2.sortInPlaceWith(((a, _), (b, _)) => a < b ? -1 : 1)
      ->Array.forEach(((groupName, group)) => {
        Js.log(groupName)
        group
        ->Js.Dict.entries
        ->Array.map(((label, values)) => (label, values->make))
        ->Js.Dict.fromArray
        ->logDictTable
      })
    }
  }
}
