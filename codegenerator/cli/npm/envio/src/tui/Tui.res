open Ink
open Belt

type params = {
  getMetrics: unit => promise<string>,
  indexerStartTime: Js.Date.t,
  envioAppUrl: string,
  envioApiToken: option<string>,
  envioVersion: option<string>,
  ecosystem: InternalConfig.ecosystem,
  hasuraUrl: string,
  hasuraPassword: string,
}

module TotalEventsProcessed = {
  @react.component
  let make = (~totalEventsProcessed) => {
    let label = "Events Processed: "
    <Text>
      <Text bold=true> {label->React.string} </Text>
      <Text color={Secondary}>
        {`${totalEventsProcessed->TuiData.formatLocaleString}`->React.string}
      </Text>
    </Text>
  }
}

module ChainLine = {
  @react.component
  let make = (
    ~chainId,
    ~maxChainIdLenght,
    ~dimensions: Hooks.dimensions,
    ~progressBlock,
    ~bufferBlock,
    ~sourceBlock,
    ~firstEventBlock,
    ~startBlock,
    ~endBlock,
    ~poweredByHyperSync,
  ) => {
    switch (progressBlock, bufferBlock, sourceBlock) {
    | (Some(progressBlock), Some(bufferBlock), Some(sourceBlock)) =>
      let toBlock = switch endBlock {
      | Some(endBlock) => Pervasives.min(sourceBlock, endBlock)
      | None => sourceBlock
      }
      let firstEventBlock = firstEventBlock->Option.getWithDefault(startBlock)

      let chainsWidth = Pervasives.min(dimensions.columns - 2, 60)
      let headerWidth = maxChainIdLenght + 10 // 10 for additional text
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
        <Box flexDirection={RowReverse} width=Num(chainsWidth)>
          <Box flexDirection={Row}>
            <Text color={Gray}> {"Blocks: "->React.string} </Text>
            <Box>
              <Text color={Gray}> {progressBlock->TuiData.formatLocaleString->React.string} </Text>
              <Text color={Gray}> {" / "->React.string} </Text>
              <Text color={Gray}> {toBlock->TuiData.formatLocaleString->React.string} </Text>
              {switch endBlock {
              | Some(_) => <Text color={Gray}> {` (End Block)`->React.string} </Text>
              | None => React.null
              }}
            </Box>
          </Box>
        </Box>
        <Newline />
      </Box>
    | (_, _, _) =>
      <Box flexDirection=Row width=Str("80%")>
        <Box width={Num(20)}>
          <Text> {"Chain: "->React.string} </Text>
          <Text bold=true> {chainId->React.string} </Text>
          <Text> {" "->React.string} </Text>
          {poweredByHyperSync ? <Text color=Secondary> {"⚡"->React.string} </Text> : React.null}
        </Box>
        <Text> {"Loading progress..."->React.string} </Text>
      </Box>
    }
  }
}

module App = {
  @react.component
  let make = (~params: params) => {
    let {envioAppUrl, envioApiToken, envioVersion, ecosystem, getMetrics} = params

    let dimensions = Hooks.useStdoutDimensions()

    let (chains, setChains) = React.useState((): array<TuiData.chain> => [])
    let totalEventsProcessed = chains->Array.reduce(0, (acc, chain) => {
      switch chain.eventsProcessed {
      | Some(count) => acc + count
      | None => acc
      }
    })
    let maxChainIdLenght = chains->Array.reduce(0, (acc, chain) => {
      let chainIdLength = chain.chainId->String.length
      if chainIdLength > acc {
        chainIdLength
      } else {
        acc
      }
    })

    // useEffect to fetch metrics every 500ms
    React.useEffect(() => {
      let intervalId = Js.Global.setInterval(() => {
        getMetrics()
        ->Promise.thenResolve(
          metricsData => {
            let parsedMetrics = TuiData.Metrics.parseMetrics(metricsData)
            let chainsFromMetrics = TuiData.Metrics.parseMetricsToChains(parsedMetrics)
            setChains(_ => chainsFromMetrics)
          },
        )
        ->Promise.catch(
          _ => {
            Js.log("Error fetching TUI metrics")
            Promise.resolve()
          },
        )
        ->ignore
      }, 500)

      Some(
        () => {
          Js.Global.clearInterval(intervalId)
        },
      )
    }, [getMetrics])

    <Box flexDirection={Column}>
      <Newline />
      <BigText
        text="envio"
        colors=[Secondary, Primary]
        font={chains->Array.length > 5 ? Tiny : Block}
        space=false
      />
      <Newline />
      {chains
      ->Array.mapWithIndex((i, chain) => {
        <ChainLine
          key={i->Int.toString}
          chainId={chain.chainId}
          maxChainIdLenght={maxChainIdLenght}
          progressBlock={chain.progressBlock}
          bufferBlock={chain.bufferBlock}
          sourceBlock={chain.sourceBlock}
          startBlock={chain.startBlock}
          endBlock={chain.endBlock}
          dimensions
          firstEventBlock=None // FIXME:
          poweredByHyperSync={chain.poweredByHyperSync}
        />
      })
      ->React.array}
      <TotalEventsProcessed totalEventsProcessed />
      // <SyncETA chains=[] indexerStartTime />
      <Newline />
      <Box flexDirection={Row}>
        <Text> {"Development Console: "->React.string} </Text>
        <Text color={Info} underline=true> {`${envioAppUrl}/console`->React.string} </Text>
      </Box>
      <Box flexDirection={Row}>
        <Text> {"GraphQL Interface:   "->React.string} </Text>
        <Text color={Info} underline=true> {params.hasuraUrl->React.string} </Text>
        // <Text color={Gray}> {` (password: ${params.hasuraPassword})`->React.string} </Text> FIXME:
      </Box>
      <Messages envioAppUrl envioApiToken envioVersion chains ecosystem />
    </Box>
  }
}

let start = params => {
  let {rerender} = render(<App params />)
  params => {
    rerender(<App params />)
  }
}
