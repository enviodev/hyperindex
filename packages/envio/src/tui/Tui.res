open Ink

module ChainLine = {
  @react.component
  let make = (
    ~chainId,
    ~maxChainIdLength,
    ~stdoutColumns: int,
    ~progressBlock,
    ~bufferBlock,
    ~sourceBlock,
    ~startBlock,
    ~endBlock,
    ~poweredByHyperSync,
    ~eventsProcessed,
    ~blockUnit: string,
  ) => {
    let chainsWidth = Pervasives.min(stdoutColumns - 2, 60)
    let headerWidth = maxChainIdLength + 10 // 10 for additional text

    switch (progressBlock, bufferBlock, sourceBlock) {
    | (Some(progressBlock), Some(bufferBlock), Some(sourceBlock)) =>
      let toBlock = switch endBlock {
      | Some(endBlock) => Pervasives.min(sourceBlock, endBlock)
      | None => sourceBlock
      }
      let progressBlockStr = progressBlock->TuiData.formatLocaleString
      let toBlockStr = toBlock->TuiData.formatLocaleString
      let eventsStr = eventsProcessed->TuiData.formatFloatLocaleString

      let endLabel = ` (End ${blockUnit})`
      let blocksText =
        `${blockUnit}s: ${progressBlockStr} / ${toBlockStr}` ++
        (endBlock->Option.isSome ? endLabel : "") ++ `  `
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
            loaded={progressBlock - startBlock}
            buffered={bufferBlock - startBlock}
            outOf={toBlock - startBlock}
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

module EventsPerSecond = {
  type sample = {time: float, events: float}

  let windowMs = 60_000.

  let computeEps = (samples: array<sample>) => {
    let len = samples->Array.length
    switch (samples->Array.get(0), samples->Array.get(len - 1)) {
    | (Some(first), Some(last)) if last.time > first.time =>
      Some((last.events -. first.events) /. ((last.time -. first.time) /. 1000.))
    | _ => None
    }
  }

  let use = (~totalEventsProcessed: float, ~tick: int) => {
    let (samples, setSamples) = React.useState((): array<sample> => [])

    React.useEffect1(() => {
      let now = Date.now()
      let cutoff = now -. windowMs
      setSamples(prev => {
        let kept = prev->Array.filter(s => s.time >= cutoff)
        kept->Array.concat([{time: now, events: totalEventsProcessed}])
      })
      None
    }, [tick])

    computeEps(samples)
  }
}

module TotalEventsProcessed = {
  @react.component
  let make = (~totalEventsProcessed, ~eventsPerSecond: option<float>) => {
    <Text>
      <Text bold=true> {"Total Events: "->React.string} </Text>
      <Text color={Secondary}>
        {`${totalEventsProcessed->TuiData.formatFloatLocaleString}`->React.string}
      </Text>
      {switch eventsPerSecond {
      | Some(eps) =>
        <Text color={Gray}>
          {` (${Math.round(eps)->TuiData.formatFloatLocaleString} events/sec)`->React.string}
        </Text>
      | None => React.null
      }}
    </Text>
  }
}

module App = {
  @react.component
  let make = (~getState) => {
    let stdoutColumns = Hooks.useStdoutColumns()
    // IndexerState is mutated in place — passing the same ref to useState
    // would bail out via Object.is and skip the re-render. Tick a counter
    // instead and read state freshly from getState() on every render.
    let (tick, setTick) = React.useState(() => 0)
    let state: IndexerState.t = getState()

    React.useEffect(() => {
      let intervalId = setInterval(() => {
        setTick(t => t + 1)
      }, 500)

      Some(
        () => {
          clearInterval(intervalId)
        },
      )
    }, [getState])

    let chains =
      state
      ->IndexerState.chainStates
      ->Dict.valuesToArray
      ->Array.map(cs => {
        let data = cs->ChainState.toChainData
        let numEventsProcessed = data.numEventsProcessed
        let committedProgressBlockNumber = cs->ChainState.committedProgressBlockNumber
        let timestampCaughtUpToHeadOrEndblock = data.timestampCaughtUpToHeadOrEndblock
        let sourceManager = cs->ChainState.sourceManager
        let latestFetchedBlockNumber = data.latestFetchedBlockNumber
        let hasProcessedToEndblock = cs->ChainState.hasProcessedToEndblock

        let firstEventBlock = data.firstEventBlockNumber
        let progress: TuiData.progress = if hasProcessedToEndblock {
          // If the endblock has been reached then set the progress to synced.
          // if there's chains that have no events in the block range start->end,
          // it's possible there are no events in that block  range (ie firstEventBlock = None)
          // This ensures TUI still displays synced in this case
          Synced({
            firstEventBlockNumber: firstEventBlock->Option.getOr(0),
            latestProcessedBlock: committedProgressBlockNumber,
            timestampCaughtUpToHeadOrEndblock: timestampCaughtUpToHeadOrEndblock->Option.getOr(
              Date.now()->Date.fromTime,
            ),
            numEventsProcessed,
          })
        } else {
          switch (firstEventBlock, timestampCaughtUpToHeadOrEndblock) {
          | (Some(firstEventBlockNumber), Some(timestampCaughtUpToHeadOrEndblock)) =>
            Synced({
              firstEventBlockNumber,
              latestProcessedBlock: committedProgressBlockNumber,
              timestampCaughtUpToHeadOrEndblock,
              numEventsProcessed,
            })
          | (Some(firstEventBlockNumber), None) =>
            Syncing({
              firstEventBlockNumber,
              latestProcessedBlock: committedProgressBlockNumber,
              numEventsProcessed,
            })
          | (None, _) => SearchingForEvents
          }
        }

        (
          {
            progress,
            knownHeight: data.knownHeight,
            latestFetchedBlockNumber,
            eventsProcessed: numEventsProcessed,
            chainId: (cs->ChainState.chainConfig).id->Int.toString,
            progressBlock: committedProgressBlockNumber < data.startBlock
              ? Some(data.startBlock)
              : Some(committedProgressBlockNumber),
            bufferBlock: Some(latestFetchedBlockNumber),
            sourceBlock: Some(cs->ChainState.knownHeight),
            firstEventBlockNumber: firstEventBlock,
            startBlock: data.startBlock,
            endBlock: data.endBlock,
            poweredByHyperSync: data.poweredByHyperSync,
            blockUnit: switch (state->IndexerState.config).ecosystem.name {
            | Svm => "Slot"
            | Evm | Fuel => "Block"
            },
            rateLimitTimeMs: sourceManager->SourceManager.getRateLimitTimeMs,
            isRateLimited: sourceManager->SourceManager.isRateLimited,
            rateLimitResetInMs: sourceManager->SourceManager.getRateLimitResetInMs,
          }: TuiData.chain
        )
      })

    let totalEventsProcessed = chains->Array.reduce(0., (acc, chain) => {
      acc +. chain.eventsProcessed
    })
    let maxChainIdLength = chains->Array.reduce(0, (acc, chain) => {
      let chainIdLength = chain.chainId->String.length
      if chainIdLength > acc {
        chainIdLength
      } else {
        acc
      }
    })
    let eventsPerSecond = EventsPerSecond.use(~totalEventsProcessed, ~tick)

    <Box flexDirection={Column}>
      <BigText
        text="envio"
        colors=[Secondary, Primary]
        font={chains->Array.length > 5 ? Tiny : Block}
        space=false
      />
      <Newline />
      {chains
      ->Array.mapWithIndex((chainData, i) => {
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
          poweredByHyperSync={chainData.poweredByHyperSync}
          eventsProcessed={chainData.eventsProcessed}
          blockUnit={chainData.blockUnit}
        />
      })
      ->React.array}
      <TotalEventsProcessed
        totalEventsProcessed
        eventsPerSecond={SyncETA.isIndexerFullySynced(chains) ? None : eventsPerSecond}
      />
      <SyncETA chains indexerStartTime={state->IndexerState.indexerStartTime} />
      {
        let maxRateLimitTimeMs =
          chains->Array.reduce(0., (acc, chain) => Pervasives.max(acc, chain.rateLimitTimeMs))
        let maxResetInMs =
          chains->Array.reduce(0.0, (acc, chain) =>
            Pervasives.max(acc, chain.rateLimitResetInMs->Option.getOr(0.0))
          )
        maxRateLimitTimeMs > 1000.
          ? {
              let rateLimitSecs = Math.round(maxRateLimitTimeMs /. 1000.)
              let activeSuffix = if maxResetInMs > 0.0 {
                let resetSecs = Pervasives.max(1.0, Math.ceil(maxResetInMs /. 1000.))
                ` (⏳ ${resetSecs->TuiData.formatFloatLocaleString}s until reset)`
              } else {
                ""
              }
              <Box flexDirection={Column}>
                <Newline />
                <Text color={Danger}>
                  {`Backfill ${rateLimitSecs->TuiData.formatFloatLocaleString}s slower due to your plan's rate limit${activeSuffix}`->React.string}
                </Text>
                <Text color={Danger}>
                  <Text color={Danger}> {"Upgrade at "->React.string} </Text>
                  <Text color={Danger} underline=true>
                    {"https://envio.dev/app/api-tokens"->React.string}
                  </Text>
                  <Text color={Danger}> {" for higher rate limits."->React.string} </Text>
                </Text>
              </Box>
            }
          : React.null
      }
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
      {if (state->IndexerState.config).isDev {
        <Box flexDirection={Row}>
          <Text> {"Dev Console: "->React.string} </Text>
          <Text color={Info} underline=true> {`${Env.envioAppUrl}/console`->React.string} </Text>
        </Box>
      } else {
        React.null
      }}
      {switch ((state->IndexerState.config).storage.clickhouse, Env.ClickHouse.host()) {
      | (true, Some(host)) =>
        <Box flexDirection={Row}>
          <Text> {"ClickHouse: "->React.string} </Text>
          <Text color={Info} underline=true> {`${host}/play`->React.string} </Text>
        </Box>
      | _ => React.null
      }}
      <Messages config={state->IndexerState.config} />
    </Box>
  }
}

let start = (~getState) => {
  let {rerender} = render(<App getState />)
  () => {
    rerender(<App getState />)
  }
}
