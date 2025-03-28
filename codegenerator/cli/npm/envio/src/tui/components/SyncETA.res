open Ink
open Belt

let isIndexerFullySynced = (chains: array<TuiData.chain>) => {
  chains->Array.reduce(true, (accum, current) => {
    switch current.progress {
    | Synced(_) => accum
    | _ => false
    }
  })
}

let getTotalRemainingBlocks = (chains: array<TuiData.chain>) => {
  chains->Array.reduce(0, (accum, {progress, knownHeight, latestFetchedBlockNumber, endBlock}) => {
    let finalBlock = switch endBlock {
    | Some(endBlock) => endBlock
    | None => knownHeight
    }
    switch progress {
    | Syncing({latestProcessedBlock})
    | Synced({latestProcessedBlock}) =>
      finalBlock - latestProcessedBlock + accum
    | SearchingForEvents => finalBlock - latestFetchedBlockNumber + accum
    }
  })
}

let getLatestTimeCaughtUpToHead = (chains: array<TuiData.chain>, indexerStartTime: Js.Date.t) => {
  let latesttimestampCaughtUpToHeadOrEndblockFloat = chains->Array.reduce(0.0, (accum, current) => {
    switch current.progress {
    | Synced({timestampCaughtUpToHeadOrEndblock}) =>
      timestampCaughtUpToHeadOrEndblock->Js.Date.valueOf > accum
        ? timestampCaughtUpToHeadOrEndblock->Js.Date.valueOf
        : accum
    | Syncing(_)
    | SearchingForEvents => accum
    }
  })

  DateFns.formatDistanceWithOptions(
    indexerStartTime,
    latesttimestampCaughtUpToHeadOrEndblockFloat->Js.Date.fromFloat,
    {includeSeconds: true},
  )
}

let getTotalBlocksProcessed = (chains: array<TuiData.chain>) => {
  chains->Array.reduce(0, (accum, {progress, latestFetchedBlockNumber}) => {
    switch progress {
    | Syncing({latestProcessedBlock, firstEventBlockNumber})
    | Synced({latestProcessedBlock, firstEventBlockNumber}) =>
      latestProcessedBlock - firstEventBlockNumber + accum
    | SearchingForEvents => latestFetchedBlockNumber + accum
    }
  })
}

let useShouldDisplayEta = (~chains: array<TuiData.chain>) => {
  let (shouldDisplayEta, setShouldDisplayEta) = React.useState(_ => false)
  React.useEffect(() => {
    //Only compute this while it is not displaying eta
    if !shouldDisplayEta {
      //Each chain should have fetched at least one batch
      let (allChainsHaveFetchedABatch, totalNumBatchesFetched) = chains->Array.reduce((true, 0), (
        (allChainsHaveFetchedABatch, totalNumBatchesFetched),
        chain,
      ) => {
        (
          allChainsHaveFetchedABatch && chain.numBatchesFetched >= 1,
          totalNumBatchesFetched + chain.numBatchesFetched,
        )
      })

      //Min num fetched batches is num of chains + 2. All
      // Chains should have fetched at least 1 batch. (They
      // could then be blocked from fetching if they are past
      //the max queue size on first batch)
      // Only display once an additinal 2 batches have been fetched to allow
      // eta to realistically stabalize
      let numChains = chains->Array.length
      let minTotalBatches = numChains + 2
      let hasMinNumBatches = totalNumBatchesFetched >= minTotalBatches

      let shouldDisplayEta = allChainsHaveFetchedABatch && hasMinNumBatches

      if shouldDisplayEta {
        setShouldDisplayEta(_ => true)
      }
    }

    None
  }, [chains])

  shouldDisplayEta
}

let useEta = (~chains, ~indexerStartTime) => {
  let shouldDisplayEta = useShouldDisplayEta(~chains)
  let (initialBlocks, setInitialBlocks) = React.useState(_ => 0.)
  let (timeSinceRestart, setTimeSinceRestart) = React.useState(_ => 0.)

  React.useEffect2(() => {
    setInitialBlocks(_ => getTotalBlocksProcessed(chains)->Int.toFloat)
    setTimeSinceRestart(_ => 0.)

    let intervalId = Js.Global.setInterval(() => {
      setTimeSinceRestart(_ => Js.Date.now() -. indexerStartTime->Js.Date.valueOf)
    }, 1000)

    Some(() => Js.Global.clearInterval(intervalId))
  }, (chains, indexerStartTime))

  //blocksProcessed/remainingBlocks = timeSoFar/eta
  //eta = (timeSoFar/blocksProcessed) * remainingBlocks

  let blocksSinceRestart = getTotalBlocksProcessed(chains)->Int.toFloat -. initialBlocks
  if shouldDisplayEta && blocksSinceRestart > 0. && timeSinceRestart > 1000. {
    let nowDate = Js.Date.now()
    let remainingBlocks = getTotalRemainingBlocks(chains)->Int.toFloat
    let etaFloat = timeSinceRestart /. blocksSinceRestart *. remainingBlocks
    let etaFloat = Pervasives.max(etaFloat, 0.0)
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
      <Text color=Primary>
        <Spinner />
      </Text>
      <Text color=Secondary> {" in progress"->React.string} </Text>
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
    <Text>
      <Text color=Primary>
        <Spinner />
      </Text>
      <Text bold=true> {" Calculating ETA..."->React.string} </Text>
    </Text>
  }
}

@react.component
let make = (~chains, ~indexerStartTime) => {
  let optEta = useEta(~chains, ~indexerStartTime)
  if isIndexerFullySynced(chains) {
    let latestTimeCaughtUpToHeadStr = getLatestTimeCaughtUpToHead(chains, indexerStartTime)
    <Synced latestTimeCaughtUpToHeadStr /> //TODO add real time
  } else {
    switch optEta {
    | Some(etaStr) => <Syncing etaStr />
    | None => <Calculating />
    }
  }
}
