type t

let make: GlobalState.t => t
let dispatchAction: (~stateId: int=?, t, GlobalState.action) => unit
let dispatchTask: (t, GlobalState.task) => unit
let getState: t => GlobalState.t
let setState: (t, GlobalState.t) => unit
