type mode = Light | Dark

let modeToString = mode => {
  switch mode {
  | Light => "light"
  | Dark => "dark"
  }
}

let stringToMode = str => {
  switch str {
  | "light" => Light
  | _ => Dark
  }
}

let useLightDarkModeLocalStorageState = () => {
  let (localStorageMode, setLocalStorageMode) = LocalStorageHooks.useLocalStorageStateAtKey(
    ~key="theme",
  )

  let mode =
    localStorageMode
    ->Option.map(modeString => {
      modeString->stringToMode
    })
    ->Option.getWithDefault(Light)

  let toggleMode = () =>
    switch mode {
    | Light => Dark
    | Dark => Light
    }
    ->modeToString
    ->setLocalStorageMode

  (mode, toggleMode)
}

module LightDarkModeToggleProvider = {
  module LightDarkModeToggleContext = {
    let context = React.createContext(Light)

    module Provider = {
      let provider = React.Context.provider(context)

      @react.component
      let make = (~value, ~children) => {
        React.createElement(provider, {value, children})
      }
    }
  }

  module DispatchLightDarkModeToggleContext = {
    let context = React.createContext(() => ())

    module Provider = {
      let provider = React.Context.provider(context)

      @react.component
      let make = (~value, ~children) => {
        React.createElement(provider, {value, children})
      }
    }
  }

  @react.component
  let make = (~children) => {
    let (mode, toggleMode) = useLightDarkModeLocalStorageState()

    <LightDarkModeToggleContext.Provider value=mode>
      <DispatchLightDarkModeToggleContext.Provider value=toggleMode>
        <div className={mode->modeToString}> {children} </div>
      </DispatchLightDarkModeToggleContext.Provider>
    </LightDarkModeToggleContext.Provider>
  }
}

let useModeUrlVariant = () => {
  let mode = React.useContext(LightDarkModeToggleProvider.LightDarkModeToggleContext.context)
  mode->modeToString
}

@react.component
let make = () => {
  let mode = React.useContext(LightDarkModeToggleProvider.LightDarkModeToggleContext.context)

  let lightDarkModeToggleDispatcher = React.useContext(
    LightDarkModeToggleProvider.DispatchLightDarkModeToggleContext.context,
  )

  <div className="flex-start flex-col items-end invisible md:visible">
    <Tooltip
      tip={"Use this toggle to switch between light and dark mode"}
      position=Tooltip.TopLeft
      hoverComponent={<div
        onClick={_ => lightDarkModeToggleDispatcher()}
        className="flex flex-row justify-center items-center">
        <div
          className={`w-14 h-7 rounded-full border ${mode == Dark
              ? "bg-primary border-white"
              : "bg-white border-primary"}`}>
          {switch mode {
          | Dark =>
            <div
              className={`ml-auto mt-1 mr-1 transform hover:-translate-x-1 transition duration-400 ease-in-out relative w-5 h-5 rounded rounded-full overflow-hidden bg-white `}
            />
          | Light =>
            <div
              className="mr-auto mt-1 ml-1 transform hover:translate-x-1 transition duration-400 ease-in-out relative w-5 h-5 rounded overflow-hidden rounded-full bg-primary"
            />
          }}
        </div>
      </div>}
    />
  </div>
}
