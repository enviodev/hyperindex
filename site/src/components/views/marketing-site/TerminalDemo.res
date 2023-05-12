// Terminal colours
// terminalBg
// terminalRed
// terminalLightBlue
// terminalDarkBlue
// terminalGreen
// terminalYellow

module TerminalLocationPlace = {
  @react.component
  let make = () => {
    <span>
      <span className="text-terminalRed"> {`Shipooor`->React.string} </span>
      <span className="text-terminalYellow"> {`@`->React.string} </span>
      <span className="text-terminalLightBlue"> {`shipping-station:`->React.string} </span>
      <span className="text-terminalYellow"> {` ➜  `->React.string} </span>
      <span className="text-terminalGreen"> {`~/envio-indexer`->React.string} </span>
      // <span className="text-terminalYellow"> {`✗ `->React.string} </span>
      <span className="text-terminalYellow"> {`$ `->React.string} </span>
    </span>
  }
}

module TerminalComment = {
  @react.component
  let make = (~comment) => {
    <span>
      <span className="text-gray-400"> {`# ${comment}`->React.string} </span>
    </span>
  }
}

module NextCommand = {
  @react.component
  let make = (~command) => {
    let typedCommand = Time.useTypedCharactersString(~delay=80, command)
    <p>
      <TerminalLocationPlace />
      {typedCommand->React.string}
      // terminal style cursor
      <span className="ml-1 w-1 h-full bg-white opacity-30"> {"c"->React.string} </span>
    </p>
  }
}

@react.component
let make = () => {
  <div
    className="md:w-code-block h-code-block bg-terminalBg rounded rounded-lg text-gray-200 mx-auto my-6">
    <div className="bg-white opacity-10 h-5 w-full" />
    <div className="px-4 py-2">
      <TerminalComment comment="Initialise a template indexer with 'envio init'" />
      <NextCommand command="envio init" />
      <Time.DelayedDisplay delay=1000>
        <p className="font-bold"> {"ENVIO v0.0.1"->React.string} </p>
      </Time.DelayedDisplay>
      <Time.DelayedDisplay delay=2000>
        <p> {"Initiating indexer boilerplate"->React.string} </p>
      </Time.DelayedDisplay>
      <Time.DelayedDisplay delay=3000>
        <TerminalComment comment={`Generate indexer with 'envio codegen'`} />
      </Time.DelayedDisplay>
      <Time.DelayedDisplay delay=4000>
        <NextCommand command="envio codegen" />
      </Time.DelayedDisplay>
      <Time.DelayedDisplay delay=5500>
        <p> {"Generating complete"->React.string} </p>
      </Time.DelayedDisplay>
      <Time.DelayedDisplay delay=6500>
        <TerminalComment comment={`Finally, deploy indexer with 'envio deploy'`} />
      </Time.DelayedDisplay>
      <Time.DelayedDisplay delay=7500>
        <NextCommand command="envio deploy" />
      </Time.DelayedDisplay>
      <Time.DelayedDisplay delay=9000>
        <p> {"Indexer deployed to:"->React.string} </p>
        <p> {"https://hosting.envio.dev/shipooor/my-indexer"->React.string} </p>
      </Time.DelayedDisplay>
      <Time.DelayedDisplay delay=10000>
        <NextCommand command="" />
      </Time.DelayedDisplay>
    </div>
  </div>
}
