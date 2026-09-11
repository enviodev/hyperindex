open Ink

module ChainLine = {
  @react.component
  let make = (
    ~chainId,
    ~maxChainIdLength,
    ~stdoutColumns: int,
    ~progressBlock: int,
    ~bufferBlock: int,
    ~toBlock: int,
    ~startBlock,
    ~endBlock,
    ~poweredByHyperSync,
    ~eventsProcessed,
    ~blockUnit: string,
  ) => {
    let chainsWidth = Pervasives.min(stdoutColumns - 2, 60)
    let headerWidth = maxChainIdLength + 10 // 10 for additional text

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
  let make = (~config: Config.t, ~getMetrics) => {
    let stdoutColumns = Hooks.useStdoutColumns()
    // Metrics are rebuilt from state mutated in place — passing the same value
    // to useState would bail out via Object.is and skip the re-render. Tick a
    // counter instead and read metrics freshly on every render.
    let (tick, setTick) = React.useState(() => 0)
    let metrics: Metrics.t = getMetrics()

    React.useEffect(() => {
      let intervalId = setInterval(() => {
        setTick(t => t + 1)
      }, 500)

      Some(
        () => {
          clearInterval(intervalId)
        },
      )
    }, [getMetrics])

    let blockUnit = switch config.ecosystem.name {
    | Svm => "Slot"
    | Evm | Fuel => "Block"
    }
    let chains = metrics.chains->Array.map(m => m->TuiData.fromChainMetrics(~blockUnit))

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
          toBlock={chainData.toBlock}
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
      <SyncETA chains indexerStartTime={metrics.startTime} />
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
      {if config.isDev {
        <Box flexDirection={Row}>
          <Text> {"Dev Console: "->React.string} </Text>
          <Text color={Info} underline=true> {`${Env.envioAppUrl}/console`->React.string} </Text>
        </Box>
      } else {
        React.null
      }}
      {switch (config.storage.clickhouse, Env.ClickHouse.host()) {
      | (true, Some(host)) =>
        <Box flexDirection={Row}>
          <Text> {"ClickHouse: "->React.string} </Text>
          <Text color={Info} underline=true> {`${host}/play`->React.string} </Text>
        </Box>
      | _ => React.null
      }}
      <Messages config />
    </Box>
  }
}

let start = (~config, ~getMetrics) => {
  let {rerender} = render(<App config getMetrics />)
  () => {
    rerender(<App config getMetrics />)
  }
}
