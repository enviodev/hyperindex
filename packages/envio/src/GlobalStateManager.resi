type t

let make: (GlobalState.t, ~onError: exn => unit=?) => t
let dispatchAction: (~stateId: int=?, t, GlobalState.action) => unit
let dispatchTask: (t, GlobalState.task) => unit
let getState: t => GlobalState.t
let setState: (t, GlobalState.t) => unit
