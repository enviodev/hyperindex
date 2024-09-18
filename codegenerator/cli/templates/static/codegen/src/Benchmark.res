module Data = {
  module BlockRangeFetched = {
    type t = {
      stats: ChainWorker.blockRangeFetchStats,
      chainId: int,
      fromBlock: int,
      toBlock: int,
      fetchStateRegisterId: FetchState.id,
      partitionId: int,
      numEvents: int,
    }

    let make = (
      ~stats,
      ~chainId,
      ~fromBlock,
      ~toBlock,
      ~fetchStateRegisterId,
      ~partitionId,
      ~numEvents,
    ) => {
      stats,
      chainId,
      fromBlock,
      toBlock,
      fetchStateRegisterId,
      partitionId,
      numEvents,
    }

    let schema = S.object(s => {
      stats: s.field("stats", ChainWorker.blockRangeFetchStatsSchema),
      chainId: s.field("chainId", S.int),
      fromBlock: s.field("fromBlock", S.int),
      toBlock: s.field("toBlock", S.int),
      fetchStateRegisterId: s.field("fetchStateRegisterId", FetchState.idSchema),
      partitionId: s.field("partitionId", S.int),
      numEvents: s.field("numEvents", S.int),
    })
  }

  type t = {requestStats: array<BlockRangeFetched.t>}
  let schema = S.object(s => {
    requestStats: s.field("requestStats", S.array(BlockRangeFetched.schema)),
  })

  let make = () => {requestStats: []}

  let addBlockRangeFetched = (self, blockRangeFetched: BlockRangeFetched.t) => {
    self.requestStats->Js.Array2.push(blockRangeFetched)->ignore
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

let addBlockRangeFetched = (
  ~stats,
  ~chainId,
  ~fromBlock,
  ~toBlock,
  ~fetchStateRegisterId,
  ~partitionId,
  ~numEvents,
) => {
  data->Data.addBlockRangeFetched(
    Data.BlockRangeFetched.make(
      ~stats,
      ~chainId,
      ~fromBlock,
      ~toBlock,
      ~fetchStateRegisterId,
      ~partitionId,
      ~numEvents,
    ),
  )

  data->saveToCacheFile
}

module Summary = {
  open Belt
  type t = {
    n: int,
    mean: float,
    stdDev: float,
    min: float,
    max: float,
  }

  type summaryTable = dict<t>

  external logSummaryTable: summaryTable => unit = "console.table"

  external arrayIntToFloat: array<int> => array<float> = "%identity"

  let make = (arr: array<float>) => {
    let div = (floatA, floatB) => floatA /. floatB
    let n = Array.length(arr)
    if n == 0 {
      {n, mean: 0., stdDev: 0., min: 0., max: 0.}
    } else {
      let nFloat = n->Int.toFloat
      let mean = arr->Array.reduce(0., (acc, time) => acc +. time)->div(nFloat)
      let stdDev = {
        let variance =
          arr
          ->Array.reduce(0., (acc, val) => {
            let diff = val -. mean
            acc +. Js.Math.pow_float(~base=diff, ~exp=2.)
          })
          ->div(nFloat)

        variance->Js.Math.sqrt
      }

      let min =
        arr
        ->Array.reduce(None, (acc, val) =>
          switch acc {
          | None => Some(val)
          | Some(acc) => Some(Pervasives.min(acc, val))
          }
        )
        ->Option.getWithDefault(0.)
      let max =
        arr
        ->Array.reduce(None, (acc, val) =>
          switch acc {
          | None => Some(val)
          | Some(acc) => Some(Pervasives.max(acc, val))
          }
        )
        ->Option.getWithDefault(0.)
      {n, mean, stdDev, min, max}
    }
  }

  let getChainBlockRangeFetchedSummary = (data: Data.t, ~chainId): summaryTable => {
    let numBlocksFetchedSamples = []
    let blockRangeSizeSamples = []
    let totalTimeElapsedSamples = []
    let parsingTimeElapsedSamples = []
    let pageFetchTimeSamples = []

    data.requestStats->Array.forEach(request =>
      if request.chainId == chainId {
        numBlocksFetchedSamples->Array.push(request.numEvents->Int.toFloat)
        blockRangeSizeSamples->Array.push(Int.toFloat(request.toBlock - request.fromBlock))
        totalTimeElapsedSamples->Array.push(request.stats.totalTimeElapsed->Int.toFloat)
        parsingTimeElapsedSamples->Array.push(
          request.stats.parsingTimeElapsed->Option.mapWithDefault(0., Int.toFloat),
        )
        pageFetchTimeSamples->Array.push(
          request.stats.pageFetchTime->Option.mapWithDefault(0., Int.toFloat),
        )
      }
    )
    [
      ("totalTimeElapsed (ms)", totalTimeElapsedSamples->make),
      ("parsingTimeElapsed (ms)", parsingTimeElapsedSamples->make),
      ("pageFetchTime (ms)", pageFetchTimeSamples->make),
      ("numBlocksFetched", numBlocksFetchedSamples->make),
      ("blockRangeSize", blockRangeSizeSamples->make),
    ]->Js.Dict.fromArray
  }
  let printSummary = async () => {
    let data = await readFromCacheFile()
    switch data {
    | None =>
      Logging.error(
        "No benchmark cache file found, please use 'ENVIO_SAVE_BENCHMARK_DATA=true' and rerun the benchmark",
      )
    | Some(data) =>
      let config = RegisterHandlers.getConfig()
      config.chainMap
      ->ChainMap.keys
      ->Array.forEach(chain => {
        Js.log2("BlockRangeFetched Summary for Chain", chain)
        let chainBlockRangeFetchedSummary =
          data->getChainBlockRangeFetchedSummary(~chainId=chain->ChainMap.Chain.toChainId)
        chainBlockRangeFetchedSummary->logSummaryTable
      })
    }
  }
}
