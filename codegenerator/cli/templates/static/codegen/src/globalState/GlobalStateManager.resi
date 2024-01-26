type t

let make: GlobalState.t => t
let dispatchAction: (t, GlobalState.action) => unit
let dispatchTask: (t, GlobalState.task) => unit
let getState: t => GlobalState.t
