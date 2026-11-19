// What the indexer reserved of the shared buffer for the queries it started, as
// its "Started querying" log lines record them. The reservation never reaches a
// source, so the log is where a scenario reads it. A line keeps one query per
// partition: the last it started that tick, which is its open-ended probe when
// it has one.

let int = json => json->JSON.Decode.float->Option.getOrThrow->Float.toInt

type started = {partitionId: string, fromBlock: int, targetBlock: option<int>, reservedItems: int}

// The last query each dispatch started per partition, one array per tick,
// oldest first.
let startedTicks = (indexer: IndexerRunner.t) =>
  indexer.allLogsAsJson()
  ->Array.filter(line => line->Dict.get("msg") == Some(JSON.String("Started querying")))
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

// The items reserved by the latest open-ended probe started for `partitionId`
// at `fromBlock`. None for a bounded query: a chunk's reservation follows from
// its density.
let probeReservation = (indexer: IndexerRunner.t, ~partitionId, ~fromBlock) =>
  indexer
  ->startedTicks
  ->Array.flat
  ->Array.findLast(query =>
    query.partitionId === partitionId && query.fromBlock === fromBlock && query.targetBlock === None
  )
  ->Option.map(query => query.reservedItems)
