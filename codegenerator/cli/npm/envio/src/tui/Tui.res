open Ink
open Belt

type chainData = ChainData.chainData
type params = {
  getMetrics: unit => promise<string>,
  chains: array<ChainData.chainData>,
  indexerStartTime: Js.Date.t,
  envioAppUrl: string,
  envioApiToken: option<string>,
  envioVersion: option<string>,
  ecosystem: InternalConfig.ecosystem,
  hasuraUrl: string,
  hasuraPassword: string,
}

let getTotalNumEventsProcessed = (~chains: array<ChainData.chainData>) => {
  chains->Array.reduce(0, (acc, chain) => {
    acc + chain.progress->ChainData.getNumberOfEventsProccessed
  })
}

module TotalEventsProcessed = {
  @react.component
  let make = (~totalEventsProcessed) => {
    let label = "Events Processed: "
    <Text>
      <Text bold=true> {label->React.string} </Text>
      <Text color={Secondary}>
        {`${totalEventsProcessed->ChainData.formatLocaleString}`->React.string}
      </Text>
    </Text>
  }
}

module App = {
  @react.component
  let make = (~params: params) => {
    let {chains, indexerStartTime, envioAppUrl, envioApiToken, envioVersion, ecosystem} = params
    let totalEventsProcessed = getTotalNumEventsProcessed(~chains)
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
        <ChainData key={i->Int.toString} chainData />
      })
      ->React.array}
      <TotalEventsProcessed totalEventsProcessed />
      <SyncETA chains indexerStartTime />
      <Newline />
      <Box flexDirection={Row}>
        <Text> {"Development Console: "->React.string} </Text>
        <Text color={Info} underline=true> {`${envioAppUrl}/console`->React.string} </Text>
      </Box>
      <Box flexDirection={Row}>
        <Text> {"GraphQL Interface:   "->React.string} </Text>
        <Text color={Info} underline=true> {params.hasuraUrl->React.string} </Text>
        <Text color={Gray}> {` (password: ${params.hasuraPassword})`->React.string} </Text>
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
