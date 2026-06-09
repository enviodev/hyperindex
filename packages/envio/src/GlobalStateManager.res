type t = {
  mutable state: GlobalState.t,
  onError: exn => unit,
  reducers: GlobalState.reducers,
}

let make = (
  state: GlobalState.t,
  ~reducers: GlobalState.reducers,
  ~onError=e => {
    e->ErrorHandling.make(~msg="Indexer has failed with an unexpected error")->ErrorHandling.log
    NodeJs.process->NodeJs.exitWithCode(Failure)
  },
) => {
  state,
  onError,
  reducers,
}

let rec dispatchAction = (~stateId=0, self: t, action: GlobalState.action) => {
  try {
    let reducer = if stateId == self.state->GlobalState.getId {
      self.reducers.actionReducer
    } else {
      self.reducers.invalidatedActionReducer
    }
    let (nextState, nextTasks) = reducer(self.state, action)
    self.state = nextState
    nextTasks->Array.forEach(task => dispatchTask(self, task))
  } catch {
  | e => e->self.onError
  }
}
and dispatchTask = (self, task: GlobalState.task) => {
  let stateId = self.state->GlobalState.getId
  NodeJs.setImmediate(() => {
    if stateId !== self.state->GlobalState.getId {
      Logging.info("Invalidated task discarded")
    } else {
      try {
        self.reducers.taskReducer(self.state, task, ~dispatchAction=action =>
          dispatchAction(~stateId, self, action)
        )
        ->Promise.catch(e => {
          e->self.onError
          Promise.resolve()
        })
        ->ignore
      } catch {
      | e => e->self.onError
      }
    }
  })
}

let getState = self => self.state
let setState = (self: t, state: GlobalState.t) => self.state = state
