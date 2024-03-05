open Ink
open Belt

let isIndexerFullySynced = (chains: array<ChainData.chainData>) => {
  chains->Array.reduce(true, (accum, current) => {
    switch current.progress {
    | Synced(_) => accum
    | _ => false
    }
  })
}
let getTotalRemainingBlocks = (chains: array<ChainData.chainData>) => {
  chains->Array.reduce(0, (accum, current) => {
    switch current.progress {
    | Syncing({latestProcessedBlock, currentBlockHeight})
    | Synced({latestProcessedBlock, currentBlockHeight}) =>
      currentBlockHeight - latestProcessedBlock + accum
    | SearchingForEvents({latestFetchedBlockNumber, currentBlockHeight}) =>
      currentBlockHeight - latestFetchedBlockNumber + accum
    }
  })
}

let getLatestTimeCaughtUpToHead = (
  chains: array<ChainData.chainData>,
  indexerStartTime: Js.Date.t,
) => {
  let latestTimeStampCaughtUpToHeadFloat = chains->Array.reduce(0.0, (accum, current) => {
    switch current.progress {
    | Synced({timestampCaughtUpToHead}) =>
      timestampCaughtUpToHead->Js.Date.valueOf > accum
        ? timestampCaughtUpToHead->Js.Date.valueOf
        : accum
    | Syncing(_)
    | SearchingForEvents(_) => accum
    }
  })

  DateFns.formatDistanceWithOptions(
    indexerStartTime,
    latestTimeStampCaughtUpToHeadFloat->Js.Date.fromFloat,
    {includeSeconds: true},
  )
}

let getTotalBlocksProcessed = (chains: array<ChainData.chainData>) => {
  chains->Array.reduce(0, (accum, current) => {
    switch current.progress {
    | Syncing({latestProcessedBlock, firstEventBlockNumber})
    | Synced({latestProcessedBlock, firstEventBlockNumber}) =>
      latestProcessedBlock - firstEventBlockNumber + accum
    | SearchingForEvents({latestFetchedBlockNumber}) => latestFetchedBlockNumber + accum
    }
  })
}

let getEta = (~chains, ~indexerStartTime) => {
  let timeSinceStart = Js.Date.now() -. indexerStartTime->Js.Date.valueOf

  //blocksProcessed/remainingBlocks = timeSoFar/eta
  //eta = (timeSoFar/blocksProcessed) * remainingBlocks

  let blocksProcessed = getTotalBlocksProcessed(chains)->Int.toFloat
  if blocksProcessed > 0. {
    let nowDate = Js.Date.now()
    let remainingBlocks = getTotalRemainingBlocks(chains)->Int.toFloat
    let etaFloat = timeSinceStart /. blocksProcessed *. remainingBlocks
    let etaFloat = Pervasives.max(etaFloat, 0.0) //template this
    let eta = (etaFloat +. nowDate)->Js.Date.fromFloat
    let interval: DateFns.interval = {start: nowDate->Js.Date.fromFloat, end: eta}
    let duration = DateFns.intervalToDuration(interval)
    let formattedDuration = DateFns.formatDuration(
      duration,
      {format: ["hours", "minutes", "seconds"]},
    )
    let outputString = switch formattedDuration {
    | "" => "less than 1 second"
    | formattedDuration => formattedDuration
    }
    Some(outputString)
  } else {
    None
  }
}

module Syncing = {
  @react.component
  let make = (~etaStr) => {
    <Text bold=true>
      <Text> {"Sync Time ETA: "->React.string} </Text>
      <Text> {etaStr->React.string} </Text>
      <Text> {" ("->React.string} </Text>
      <Text color=Secondary> {"in progress"->React.string} </Text>
      <Text> {")"->React.string} </Text>
    </Text>
  }
}

module Synced = {
  @react.component
  let make = (~latestTimeCaughtUpToHeadStr) => {
    <Text bold=true>
      <Text> {"Time Synced: "->React.string} </Text>
      <Text> {`${latestTimeCaughtUpToHeadStr}`->React.string} </Text>
      <Text> {" ("->React.string} </Text>
      <Text color=Success> {"synced"->React.string} </Text>
      <Text> {")"->React.string} </Text>
    </Text>
  }
}

module Calculating = {
  @react.component
  let make = () => {
    <Text bold=true> {"Calculating ETA..."->React.string} </Text>
  }
}

@react.component
let make = (~chains, ~indexerStartTime) => {
  if isIndexerFullySynced(chains) {
    let latestTimeCaughtUpToHeadStr = getLatestTimeCaughtUpToHead(chains, indexerStartTime)
    <Synced latestTimeCaughtUpToHeadStr /> //TODO add real time
  } else {
    switch getEta(~chains, ~indexerStartTime) {
    | Some(etaStr) => <Syncing etaStr />
    | None => <Calculating />
    }
  }
}
