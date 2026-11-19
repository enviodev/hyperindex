// What the indexer reserved of the shared buffer for the queries it started,
// as its "Started querying" log lines record them. The reservation never
// reaches a source, so the log is where a scenario reads it.

let int = json => json->JSON.Decode.float->Option.getOrThrow->Float.toInt

let startedQueriesPerTick = (indexer: IndexerRunner.t) =>
  indexer.allLogsAsJson()
  ->Array.filter(line => line->Dict.get("msg") == Some(JSON.String("Started querying")))
  ->Array.map(line =>
    line
    ->Dict.get("queries")
    ->Option.flatMap(JSON.Decode.array)
    ->Option.getOr([])
    ->Array.filterMap(JSON.Decode.object)
  )

type started = {partitionId: string, fromBlock: int, reservedItems: int}

// The queries each dispatch started, one array per tick, oldest first.
let startedTicks = (indexer: IndexerRunner.t) =>
  indexer
  ->startedQueriesPerTick
  ->Array.map(queries =>
    queries->Array.map(query => {
      partitionId: query->Dict.getUnsafe("partitionId")->JSON.Decode.string->Option.getOrThrow,
      fromBlock: query->Dict.getUnsafe("fromBlock")->int,
      reservedItems: query->Dict.getUnsafe("reservedItems")->int,
    })
  )

// The items reserved by the latest probe started for `partitionId` at
// `fromBlock`. None for a chunk: its reservation follows from its density.
let probeReservation = (indexer: IndexerRunner.t, ~partitionId, ~fromBlock) =>
  indexer
  ->startedQueriesPerTick
  ->Array.flat
  ->Array.findLast(query =>
    query->Dict.get("partitionId") == Some(JSON.String(partitionId)) &&
    query->Dict.get("fromBlock")->Option.map(int) == Some(fromBlock) &&
    query->Dict.get("isChunk") == Some(JSON.Boolean(false))
  )
  ->Option.map(query => query->Dict.getUnsafe("reservedItems")->int)
