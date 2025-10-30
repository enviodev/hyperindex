type t

let make: (GlobalState.t, ~stateUpdatedHook: GlobalState.t => unit=?, ~onError: exn => unit=?) => t
let dispatchAction: (~stateId: int=?, t, GlobalState.action) => unit
let dispatchTask: (t, GlobalState.task) => unit
let getState: t => GlobalState.t
let setState: (t, GlobalState.t) => unit
