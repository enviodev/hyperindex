type t = {referrer: string}
type action = SetReferrer(string)

let defaultMiscState = {
  referrer: "",
}

module MiscContext = {
  let context = React.createContext({referrer: ""})

  module Provider = {
    let provider = React.Context.provider(context)

    @react.component
    let make = (~value, ~children) => {
      React.createElement(provider, {value, children})
    }
  }
}

module DispatchMiscContext = {
  let context = React.createContext((_action: action) => ())

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
  let (state, dispatch) = React.useReducer((_state, action) => {
    switch action {
    | SetReferrer(referrer) => {
        // ...state,
        referrer: referrer,
      }
    }
  }, defaultMiscState)
  <MiscContext.Provider value=state>
    <DispatchMiscContext.Provider value=dispatch>
      <div> {children} </div>
    </DispatchMiscContext.Provider>
  </MiscContext.Provider>
}
