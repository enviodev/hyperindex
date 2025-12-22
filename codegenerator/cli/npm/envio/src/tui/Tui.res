open Ink
open Belt

module ChainLine = {
  @react.component
  let make = (
    ~chainId,
    ~maxChainIdLength,
    ~stdoutColumns: int,
    ~progressBlock,
    ~bufferBlock,
    ~sourceBlock,
    ~firstEventBlock,
    ~startBlock,
    ~endBlock,
    ~poweredByHyperSync,
    ~eventsProcessed,
  ) => {
    let chainsWidth = Pervasives.min(stdoutColumns - 2, 60)
    let headerWidth = maxChainIdLength + 10 // 10 for additional text

    switch (progressBlock, bufferBlock, sourceBlock) {
    | (Some(progressBlock), Some(bufferBlock), Some(sourceBlock)) =>
      let toBlock = switch endBlock {
      | Some(endBlock) => Pervasives.min(sourceBlock, endBlock)
      | None => sourceBlock
      }
      let firstEventBlock = firstEventBlock->Option.getWithDefault(startBlock)

      let progressBlockStr = progressBlock->TuiData.formatLocaleString
      let toBlockStr = toBlock->TuiData.formatLocaleString
      let eventsStr = eventsProcessed->TuiData.formatLocaleString

      let blocksText =
        `Blocks: ${progressBlockStr} / ${toBlockStr}` ++
        (endBlock->Option.isSome ? " (End Block)" : "") ++ `  `
      let eventsText = `Events: ${eventsStr}`

      let fitsSameLine = blocksText->String.length + eventsText->String.length <= chainsWidth

      <Box flexDirection={Column}>
        <Box flexDirection=Row width=Num(chainsWidth)>
          <Box width={Num(headerWidth)}>
            <Text> {"Chain: "->React.string} </Text>
            <Text bold=true> {chainId->React.string} </Text>
            <Text> {" "->React.string} </Text>
            {poweredByHyperSync ? <Text color=Secondary> {"⚡"->React.string} </Text> : React.null}
          </Box>
          <BufferedProgressBar
            barWidth={chainsWidth - headerWidth}
            loaded={progressBlock - firstEventBlock}
            buffered={bufferBlock - firstEventBlock}
            outOf={toBlock - firstEventBlock}
            loadingColor={Secondary}
          />
        </Box>
        <Box flexDirection={Row}>
          <Text color={Gray}> {blocksText->React.string} </Text>
          {fitsSameLine ? <Text color={Gray}> {eventsText->React.string} </Text> : React.null}
        </Box>
        {fitsSameLine
          ? React.null
          : <Box flexDirection={Row}>
              <Text color={Gray}> {eventsText->String.trim->React.string} </Text>
            </Box>}
        <Newline />
      </Box>
    | (_, _, _) =>
      <>
        <Box flexDirection=Row width=Num(chainsWidth)>
          <Box width={Num(headerWidth)}>
            <Text> {"Chain: "->React.string} </Text>
            <Text bold=true> {chainId->React.string} </Text>
            <Text> {" "->React.string} </Text>
            {poweredByHyperSync ? <Text color=Secondary> {"⚡"->React.string} </Text> : React.null}
          </Box>
          <Text> {"Loading progress..."->React.string} </Text>
        </Box>
        <Newline />
      </>
    }
  }
}

module TotalEventsProcessed = {
  @react.component
  let make = (~totalEventsProcessed) => {
    let label = "Total Events: "
    <Text>
      <Text bold=true> {label->React.string} </Text>
      <Text color={Secondary}>
        {`${totalEventsProcessed->TuiData.formatLocaleString}`->React.string}
      </Text>
    </Text>
  }
}

module App = {
  @react.component
  let make = (~getState) => {
    let stdoutColumns = Hooks.useStdoutColumns()
    let (state: GlobalState.t, setState) = React.useState(() => getState())

    // useEffect to refresh state every 500ms
    React.useEffect(() => {
      let intervalId = Js.Global.setInterval(() => {
        setState(_ => getState())
      }, 500)

      Some(
        () => {
          Js.Global.clearInterval(intervalId)
        },
      )
    }, [getState])

    let chains =
      state.chainManager.chainFetchers
      ->ChainMap.values
      ->Array.map(cf => {
        let {numEventsProcessed, fetchState, numBatchesFetched} = cf
        let latestFetchedBlockNumber = Pervasives.max(fetchState->FetchState.bufferBlockNumber, 0)
        let hasProcessedToEndblock = cf->ChainFetcher.hasProcessedToEndblock
        let knownHeight =
          cf->ChainFetcher.hasProcessedToEndblock
            ? cf.fetchState.endBlock->Option.getWithDefault(cf.fetchState.knownHeight)
            : cf.fetchState.knownHeight

        let progress: TuiData.progress = if hasProcessedToEndblock {
          // If the endblock has been reached then set the progress to synced.
          // if there's chains that have no events in the block range start->end,
          // it's possible there are no events in that block  range (ie firstEventBlockNumber = None)
          // This ensures TUI still displays synced in this case
          let {
            committedProgressBlockNumber,
            timestampCaughtUpToHeadOrEndblock,
            numEventsProcessed,
            firstEventBlockNumber,
          } = cf

          Synced({
            firstEventBlockNumber: firstEventBlockNumber->Option.getWithDefault(0),
            latestProcessedBlock: committedProgressBlockNumber,
            timestampCaughtUpToHeadOrEndblock: timestampCaughtUpToHeadOrEndblock->Option.getWithDefault(
              Js.Date.now()->Js.Date.fromFloat,
            ),
            numEventsProcessed,
          })
        } else {
          switch cf {
          | {
              committedProgressBlockNumber,
              timestampCaughtUpToHeadOrEndblock: Some(timestampCaughtUpToHeadOrEndblock),
              firstEventBlockNumber: Some(firstEventBlockNumber),
            } =>
            Synced({
              firstEventBlockNumber,
              latestProcessedBlock: committedProgressBlockNumber,
              timestampCaughtUpToHeadOrEndblock,
              numEventsProcessed,
            })
          | {
              committedProgressBlockNumber,
              timestampCaughtUpToHeadOrEndblock: None,
              firstEventBlockNumber: Some(firstEventBlockNumber),
            } =>
            Syncing({
              firstEventBlockNumber,
              latestProcessedBlock: committedProgressBlockNumber,
              numEventsProcessed,
            })
          | {firstEventBlockNumber: None} => SearchingForEvents
          }
        }

        (
          {
            progress,
            knownHeight,
            latestFetchedBlockNumber,
            numBatchesFetched,
            eventsProcessed: numEventsProcessed,
            chainId: cf.chainConfig.id->Int.toString,
            progressBlock: cf.committedProgressBlockNumber === -1
              ? None
              : Some(cf.committedProgressBlockNumber),
            bufferBlock: Some(latestFetchedBlockNumber),
            sourceBlock: Some(cf.fetchState.knownHeight),
            firstEventBlockNumber: cf.firstEventBlockNumber,
            startBlock: cf.fetchState.startBlock,
            endBlock: cf.fetchState.endBlock,
            poweredByHyperSync: (
              cf.sourceManager->SourceManager.getActiveSource
            ).poweredByHyperSync,
          }: TuiData.chain
        )
      })

    let totalEventsProcessed = chains->Array.reduce(0, (acc, chain) => {
      acc + chain.eventsProcessed
    })
    let maxChainIdLength = chains->Array.reduce(0, (acc, chain) => {
      let chainIdLength = chain.chainId->String.length
      if chainIdLength > acc {
        chainIdLength
      } else {
        acc
      }
    })

    <Box flexDirection={Column}>
      <BigText
        text="envio"
        colors=[Secondary, Primary]
        font={chains->Array.length > 5 ? Tiny : Block}
        space=false
      />
      <Newline />
      {chains
      ->Array.mapWithIndex((i, chainData) => {
        <ChainLine
          key={i->Int.toString}
          chainId={chainData.chainId}
          maxChainIdLength={maxChainIdLength}
          progressBlock={chainData.progressBlock}
          bufferBlock={chainData.bufferBlock}
          sourceBlock={chainData.sourceBlock}
          startBlock={chainData.startBlock}
          endBlock={chainData.endBlock}
          stdoutColumns={stdoutColumns}
          firstEventBlock={chainData.firstEventBlockNumber}
          poweredByHyperSync={chainData.poweredByHyperSync}
          eventsProcessed={chainData.eventsProcessed}
        />
      })
      ->React.array}
      <TotalEventsProcessed totalEventsProcessed />
      <SyncETA chains indexerStartTime=state.indexerStartTime />
      <Newline />
      <Box flexDirection={Row}>
        <Text> {"GraphQL: "->React.string} </Text>
        <Text color={Info} underline=true> {Env.Hasura.url->React.string} </Text>
        {
          let defaultPassword = "testing"
          if Env.Hasura.secret == defaultPassword {
            <Text color={Gray}> {` (password: ${defaultPassword})`->React.string} </Text>
          } else {
            React.null
          }
        }
      </Box>
      <Box flexDirection={Row}>
        <Text> {"Dev Console: "->React.string} </Text>
        <Text color={Info} underline=true> {`${Env.envioAppUrl}/console`->React.string} </Text>
      </Box>
      <Messages config=state.indexer.config />
    </Box>
  }
}

let start = (~getState) => {
  let {rerender} = render(<App getState />)
  () => {
    rerender(<App getState />)
  }
}
