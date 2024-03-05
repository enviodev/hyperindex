open Ink
open Belt

type chainData = ChainData.chainData
type appState = {
  chains: array<ChainData.chainData>,
  indexerStartTime: Js.Date.t,
}

module App = {
  @react.component
  let make = (~appState: appState) => {
    let {chains, indexerStartTime} = appState
    let hasuraPort = "8080"
    let hasuraLink = `http://localhost:${hasuraPort}`
    <Box flexDirection={Column}>
      <BigText text="envio" colors=[Secondary, Primary] font={Block} />
      {chains
      ->Array.mapWithIndex((i, chainData) => {
        <ChainData key={i->Int.toString} chainData />
      })
      ->React.array}
      <SyncETA chains indexerStartTime />
      <Newline />
      <Box flexDirection={Column}>
        <Text bold=true> {"GraphQL:"->React.string} </Text>
        <Text color={Info} underline=true> {hasuraLink->React.string} </Text>
      </Box>
    </Box>
  }
}

let startApp = appState => {
  let {rerender} = render(<App appState />)
  appState => {
    rerender(<App appState />)
  }
}
