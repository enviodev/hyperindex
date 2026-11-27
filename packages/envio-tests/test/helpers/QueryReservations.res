// What the indexer reserved of the shared buffer for the requests it started, as
// its "Started querying" log lines record them. The reservation never reaches a
// source, so the log is where a scenario reads it.

let int = json => json->JSON.Decode.float->Option.getOrThrow->Float.toInt

type started = {fromBlock: int, targetBlock: option<int>, reservedItems: int}

// The requests each dispatch started, one array per tick, oldest first. With
// `chainId`, only that chain's dispatches.
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
    ->Dict.get("requests")
    ->Option.flatMap(JSON.Decode.array)
    ->Option.getOr([])
    ->Array.map(request => {
      let request = request->JSON.Decode.object->Option.getOrThrow
      {
        fromBlock: request->Dict.getUnsafe("fromBlock")->int,
        targetBlock: request
        ->Dict.get("toBlock")
        ->Option.flatMap(JSON.Decode.float)
        ->Option.map(Float.toInt),
        reservedItems: request->Dict.getUnsafe("targetEvents")->int,
      }
    })
  )

let latestStarted = (indexer, ~chainId=?, ~fromBlock, ~isMatch) =>
  indexer
  ->startedTicks(~chainId?)
  ->Array.flat
  ->Array.findLast(request => request.fromBlock === fromBlock && isMatch(request))

// The items reserved by the latest request started at `fromBlock`.
let reservation = (indexer, ~chainId=?, ~fromBlock) =>
  indexer
  ->latestStarted(~chainId?, ~fromBlock, ~isMatch=_ => true)
  ->Option.map(request => request.reservedItems)

// The items reserved by the latest open-ended probe started at `fromBlock`.
// None for a bounded request: a chunk's reservation follows from its density.
let probeReservation = (indexer, ~chainId=?, ~fromBlock) =>
  indexer
  ->latestStarted(~chainId?, ~fromBlock, ~isMatch=request => request.targetBlock === None)
  ->Option.map(request => request.reservedItems)
