open Ink
open Belt

type chainData = ChainData.chainData
type appState = {
  chains: array<ChainData.chainData>,
  indexerStartTime: Js.Date.t,
  config: Config.t,
  isPreRegisteringDynamicContracts: bool,
}

let getTotalNumEventsProcessed = (~chains: array<ChainData.chainData>) => {
  chains->Array.reduce(0, (acc, chain) => {
    acc + chain.progress->ChainData.getNumberOfEventsProccessed
  })
}

module TotalEventsProcessed = {
  @react.component
  let make = (~totalEventsProcessed, ~isPreRegisteringDynamicContracts) => {
    let label = isPreRegisteringDynamicContracts
      ? "Total Contracts Registered: "
      : "Total Events Processed: "
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
  let make = () => {
    <Box flexDirection={Column}>
      <BigText text="envio" colors=[Secondary, Primary] font={Block} />
      <Box flexDirection={Column}>
        <Text>
          {"Track the indexer's progress and access GraphQL Playground at the Development Console:"->React.string}
        </Text>
        <Text color={Info} underline=true> {"https://envio.dev/console"->React.string} </Text>
      </Box>
      // <Messages config /> TODO: Rerturn it back
    </Box>
  }
}

let startApp = () => {
  let _ = render(<App />)
}
