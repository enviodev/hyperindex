// What the indexer reserved of the shared buffer for the queries it started, as
// its "Started querying" log lines record them. The reservation never reaches a
// source, so the log is where a scenario reads it. A line keeps one query per
// partition: the last it started that tick, which is its open-ended probe when
// it has one.

let int = json => json->JSON.Decode.float->Option.getOrThrow->Float.toInt

type started = {partitionId: string, fromBlock: int, targetBlock: option<int>, reservedItems: int}

// The last query each dispatch started per partition, one array per tick,
// oldest first. With `chainId`, only that chain's dispatches.
let startedTicks = (indexer: IndexerRunner.t, ~chainId=?) =>
  indexer.allLogsAsJson()
  ->Array.filter(line =>
    line->Dict.get("msg") == Some(JSON.String("Started querying")) &&
      switch chainId {
      | Some(chainId) => line->Dict.get("chainId") == Some(JSON.Number(chainId->Int.toFloat))
      | None => true
      }
  )
  ->Array.map(line =>
    line
    ->Dict.get("partitions")
    ->Option.flatMap(JSON.Decode.object)
    ->Option.getOr(Dict.make())
    ->Dict.toArray
    ->Array.map(((partitionId, query)) => {
      let query = query->JSON.Decode.object->Option.getOrThrow
      {
        partitionId,
        fromBlock: query->Dict.getUnsafe("fromBlock")->int,
        targetBlock: query
        ->Dict.get("targetBlock")
        ->Option.flatMap(JSON.Decode.float)
        ->Option.map(Float.toInt),
        reservedItems: query->Dict.getUnsafe("targetEvents")->int,
      }
    })
  )

let latestStarted = (indexer, ~chainId=?, ~partitionId, ~fromBlock, ~isMatch) =>
  indexer
  ->startedTicks(~chainId?)
  ->Array.flat
  ->Array.findLast(query =>
    query.partitionId === partitionId && query.fromBlock === fromBlock && isMatch(query)
  )

// The items reserved by the latest query started for `partitionId` at
// `fromBlock`.
let reservation = (indexer, ~chainId=?, ~partitionId, ~fromBlock) =>
  indexer
  ->latestStarted(~chainId?, ~partitionId, ~fromBlock, ~isMatch=_ => true)
  ->Option.map(query => query.reservedItems)

// The items reserved by the latest open-ended probe started for `partitionId`
// at `fromBlock`. None for a bounded query: a chunk's reservation follows from
// its density.
let probeReservation = (indexer, ~chainId=?, ~partitionId, ~fromBlock) =>
  indexer
  ->latestStarted(~chainId?, ~partitionId, ~fromBlock, ~isMatch=query => query.targetBlock === None)
  ->Option.map(query => query.reservedItems)
