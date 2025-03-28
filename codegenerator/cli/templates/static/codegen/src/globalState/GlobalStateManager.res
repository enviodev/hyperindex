open Belt
module type State = {
  type t
  type action
  type task

  let taskReducer: (t, task, ~dispatchAction: action => unit) => promise<unit>
  let actionReducer: (t, action) => (t, array<task>)
  let invalidatedActionReducer: (t, action) => (t, array<task>)
  let getId: t => int
}

module MakeManager = (S: State) => {
  type t = {mutable state: S.t, stateUpdatedHook: option<S.t => unit>}

  let make = (~stateUpdatedHook: option<S.t => unit>=?, state: S.t) => {state, stateUpdatedHook}

  let rec dispatchAction = (~stateId=0, self: t, action: S.action) => {
    try {
      let reducer = if stateId == self.state->S.getId {
        S.actionReducer
      } else {
        S.invalidatedActionReducer
      }
      let (nextState, nextTasks) = reducer(self.state, action)
      switch self.stateUpdatedHook {
      // In ReScript `!==` is shallow equality check rather than `!=`
      // This is just a check to see if a new object reference was returned
      | Some(hook) if self.state !== nextState => hook(nextState)
      | _ => ()
      }
      self.state = nextState
      nextTasks->Array.forEach(task => dispatchTask(self, task))
    } catch {
    | e =>
      e->ErrorHandling.make(~msg="Indexer has failed with an unxpected error")->ErrorHandling.log
      NodeJs.process->NodeJs.exitWithCode(Failure)
    }
  }
  and dispatchTask = (self, task: S.task) => {
    let stateId = self.state->S.getId
    Js.Global.setTimeout(() => {
      if stateId !== self.state->S.getId {
        Logging.info("Invalidated task discarded")
      } else {
        S.taskReducer(self.state, task, ~dispatchAction=action =>
          dispatchAction(~stateId, self, action)
        )->ignore
      }
    }, 0)->ignore
  }

  let getState = self => self.state
  let setState = (self: t, state: S.t) => self.state = state
}

module Manager = MakeManager(GlobalState)
include Manager
