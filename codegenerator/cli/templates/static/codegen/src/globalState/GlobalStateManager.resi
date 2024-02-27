type t

let make: (~stateUpdatedHook: GlobalState.t => unit=?, GlobalState.t) => t
let dispatchAction: (t, GlobalState.action) => unit
let dispatchTask: (t, GlobalState.task) => unit
let getState: t => GlobalState.t
