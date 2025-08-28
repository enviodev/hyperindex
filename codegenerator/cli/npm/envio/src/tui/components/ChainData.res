open Ink

type syncing = {
  firstEventBlockNumber: int,
  latestProcessedBlock: int,
  numEventsProcessed: int,
}
type synced = {
  ...syncing,
  timestampCaughtUpToHeadOrEndblock: Js.Date.t,
}

type progress = SearchingForEvents | Syncing(syncing) | Synced(synced)

let getNumberOfEventsProccessed = (progress: progress) => {
  switch progress {
  | SearchingForEvents => 0
  | Syncing(syncing) => syncing.numEventsProcessed
  | Synced(synced) => synced.numEventsProcessed
  }
}
type chainData = {
  chain: ChainMap.Chain.t,
  poweredByHyperSync: bool,
  progress: progress,
  latestFetchedBlockNumber: int,
  currentBlockHeight: int,
  numBatchesFetched: int,
  endBlock: option<int>,
}

let minOfOption: (int, option<int>) => int = (a: int, b: option<int>) => {
  switch (a, b) {
  | (a, Some(b)) => min(a, b)
  | (a, None) => a
  }
}

type number
@val external number: int => number = "Number"
@send external toLocaleString: number => string = "toLocaleString"
let formatLocaleString = n => n->number->toLocaleString

module BlocksDisplay = {
  @react.component
  let make = (~latestProcessedBlock, ~currentBlockHeight) => {
    <Box flexDirection={Row}>
      <Text color={Gray}> {"Blocks: "->React.string} </Text>
      <Box>
        <Text color={Gray}> {latestProcessedBlock->formatLocaleString->React.string} </Text>
        <Text color={Gray}> {" / "->React.string} </Text>
        <Text color={Gray}> {currentBlockHeight->formatLocaleString->React.string} </Text>
      </Box>
    </Box>
  }
}

module SyncBar = {
  @react.component
  let make = (
    ~chainId,
    ~loaded,
    ~buffered=?,
    ~outOf,
    ~loadingColor,
    ~poweredByHyperSync=true,
    ~isSearching=false,
  ) => {
    <Box flexDirection=Row width=Str("80%")>
      <Box width={Num(20)}>
        <Text> {"Chain: "->React.string} </Text>
        <Text bold=true> {chainId->React.int} </Text>
        <Text> {" "->React.string} </Text>
        {poweredByHyperSync ? <Text color=Secondary> {"⚡"->React.string} </Text> : React.null}
      </Box>
      {isSearching
        ? <Text color={Primary}>
            <Spinner type_={Aesthetic} />
          </Text>
        : <BufferedProgressBar loaded ?buffered outOf loadingColor />}
    </Box>
  }
}

@react.component
let make = (~chainData: chainData) => {
  let {
    chain,
    progress,
    poweredByHyperSync,
    latestFetchedBlockNumber,
    currentBlockHeight,
    endBlock,
  } = chainData
  let chainId = chain->ChainMap.Chain.toChainId

  let toBlock = minOfOption(currentBlockHeight, endBlock)

  switch progress {
  | SearchingForEvents =>
    <Box flexDirection={Column}>
      <SyncBar
        chainId
        loaded={latestFetchedBlockNumber}
        outOf={toBlock}
        loadingColor={Primary}
        poweredByHyperSync
        isSearching=true
      />
      <Box flexDirection={Row} justifyContent={SpaceBetween} width=Num(57)>
        <Text> {"Searching for events..."->React.string} </Text>
        <BlocksDisplay latestProcessedBlock=latestFetchedBlockNumber currentBlockHeight=toBlock />
      </Box>
      <Newline />
    </Box>
  | Syncing({firstEventBlockNumber, latestProcessedBlock}) =>
    <Box flexDirection={Column}>
      <SyncBar
        chainId
        loaded={latestProcessedBlock - firstEventBlockNumber}
        buffered={latestFetchedBlockNumber - firstEventBlockNumber}
        outOf={toBlock - firstEventBlockNumber}
        loadingColor={Secondary}
        poweredByHyperSync
      />
      <Box flexDirection={RowReverse} width=Num(57)>
        <BlocksDisplay latestProcessedBlock currentBlockHeight=toBlock />
      </Box>
      <Newline />
    </Box>
  | Synced({firstEventBlockNumber, latestProcessedBlock}) =>
    <Box flexDirection={Column}>
      <SyncBar
        chainId
        loaded={latestProcessedBlock - firstEventBlockNumber}
        buffered={latestFetchedBlockNumber - firstEventBlockNumber}
        outOf={toBlock - firstEventBlockNumber}
        loadingColor=Success
        poweredByHyperSync
      />
      <Box flexDirection={RowReverse} width=Num(57)>
        <BlocksDisplay latestProcessedBlock currentBlockHeight=toBlock />
      </Box>
      <Newline />
    </Box>
  }
}
