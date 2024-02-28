open Ink

type searching = {
  latestFetchedBlockNumber: int,
  currentBlockHeight: int,
}

type syncing = {
  ...searching,
  firstEventBlockNumber: int,
  latestProcessedBlock: int,
  numEventsProcessed: int,
}
type synced = {
  ...syncing,
  timestampCaughtUpToHead: Js.Date.t,
}

type progress = SearchingForEvents(searching) | Syncing(syncing) | Synced(synced)
type chainData = {
  chainId: int,
  isHyperSync: bool,
  progress: progress,
}

module BlocksDisplay = {
  @react.component
  let make = (~latestProcessedBlock, ~currentBlockHeight) => {
    <Box flexDirection={Row}>
      <Text> {"blocks: "->React.string} </Text>
      <Box flexDirection={Column} alignItems={FlexEnd}>
        <Box>
          <Text> {latestProcessedBlock->React.int} </Text>
        </Box>
        <Box>
          <Text> {"/"->React.string} </Text>
          <Text> {currentBlockHeight->React.int} </Text>
        </Box>
      </Box>
    </Box>
  }
}

module SyncBar = {
  @react.component
  let make = (~chainId, ~loaded, ~buffered=?, ~outOf, ~loadingColor, ~isHyperSync=true) => {
    <Box flexDirection=Row width=Str("80%")>
      <Box width={Num(20)}>
        {isHyperSync ? <Text color=Secondary> {"⚡"->React.string} </Text> : React.null}
        <Text> {"Chain ID: "->React.string} </Text>
        <Text> {chainId->React.int} </Text>
        <Text> {" "->React.string} </Text>
      </Box>
      <BufferedProgressBar loaded ?buffered outOf loadingColor />
    </Box>
  }
}

@react.component
let make = (~chainData: chainData) => {
  let {chainId, progress, isHyperSync} = chainData

  switch progress {
  | SearchingForEvents({latestFetchedBlockNumber, currentBlockHeight}) =>
    <Box flexDirection={Column}>
      <Box flexDirection={Row} justifyContent={SpaceBetween} width=Num(57)>
        <Text> {"Searching..."->React.string} </Text>
        <BlocksDisplay latestProcessedBlock=latestFetchedBlockNumber currentBlockHeight />
      </Box>
      <SyncBar
        chainId
        loaded={latestFetchedBlockNumber}
        outOf={currentBlockHeight}
        loadingColor={Primary}
        isHyperSync
      />
      <Newline />
    </Box>
  | Syncing({
      latestFetchedBlockNumber,
      currentBlockHeight,
      firstEventBlockNumber,
      latestProcessedBlock,
      numEventsProcessed,
    }) =>
    <Box flexDirection={Column}>
      <Box flexDirection={Row} justifyContent={SpaceBetween} width=Num(57)>
        <Box>
          <Text> {"Events Processed: "->React.string} </Text>
          <Text bold=true> {numEventsProcessed->React.int} </Text>
        </Box>
        <BlocksDisplay latestProcessedBlock currentBlockHeight />
      </Box>
      <SyncBar
        chainId
        loaded={latestProcessedBlock - firstEventBlockNumber}
        buffered={latestFetchedBlockNumber - firstEventBlockNumber}
        outOf={currentBlockHeight - firstEventBlockNumber}
        loadingColor=Secondary
        isHyperSync
      />
      <Newline />
    </Box>
  | Synced({
      latestFetchedBlockNumber,
      currentBlockHeight,
      firstEventBlockNumber,
      latestProcessedBlock,
      numEventsProcessed,
    }) =>
    <Box flexDirection={Column}>
      <Box flexDirection={Row} justifyContent={SpaceBetween} width=Num(57)>
        <Box>
          <Text> {"Events Processed: "->React.string} </Text>
          <Text bold=true> {numEventsProcessed->React.int} </Text>
        </Box>
        <BlocksDisplay latestProcessedBlock currentBlockHeight />
      </Box>
      <SyncBar
        chainId
        loaded={latestProcessedBlock - firstEventBlockNumber}
        buffered={latestFetchedBlockNumber - firstEventBlockNumber}
        outOf={currentBlockHeight - firstEventBlockNumber}
        loadingColor=Success
        isHyperSync
      />
      <Newline />
    </Box>
  }
}
