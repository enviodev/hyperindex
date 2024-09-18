module Data = {
  module BlockRangeFetched = {
    type t = {
      stats: ChainWorker.blockRangeFetchStats,
      chainId: int,
      fromBlock: int,
      toBlock: int,
      fetchStateRegisterId: FetchState.id,
      partitionId: int,
    }

    let make = (~stats, ~chainId, ~fromBlock, ~toBlock, ~fetchStateRegisterId, ~partitionId) => {
      stats,
      chainId,
      fromBlock,
      toBlock,
      fetchStateRegisterId,
      partitionId,
    }

    let schema = S.object(s => {
      stats: s.field("stats", ChainWorker.blockRangeFetchStatsSchema),
      chainId: s.field("chainId", S.int),
      fromBlock: s.field("fromBlock", S.int),
      toBlock: s.field("toBlock", S.int),
      fetchStateRegisterId: s.field("fetchStateRegisterId", FetchState.idSchema),
      partitionId: s.field("partitionId", S.int),
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

let addBlockRangeFetched = (
  ~stats,
  ~chainId,
  ~fromBlock,
  ~toBlock,
  ~fetchStateRegisterId,
  ~partitionId,
) => {
  data->Data.addBlockRangeFetched(
    Data.BlockRangeFetched.make(
      ~stats,
      ~chainId,
      ~fromBlock,
      ~toBlock,
      ~fetchStateRegisterId,
      ~partitionId,
    ),
  )

  data->saveToCacheFile
}
