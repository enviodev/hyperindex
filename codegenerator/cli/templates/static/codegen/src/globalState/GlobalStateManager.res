open Belt
module type State = {
  type t
  type action
  type task

  let taskReducer: (t, task, ~dispatchAction: action => unit) => unit
  let actionReducer: (t, action) => (t, array<task>)
}

module MakeManager = (S: State) => {
  type t = {mutable state: S.t}

  let make = (state: S.t) => {state: state}

  let rec dispatchAction = (self: t, action: S.action) => {
    Js.Global.setTimeout(() => {
      let (nextState, nextTasks) = S.actionReducer(self.state, action)
      self.state = nextState

      nextTasks->Array.forEach(task => dispatchTask(self, task))
    }, 0)->ignore
  }
  and dispatchTask = (self, task: S.task) => Js.Global.setTimeout(() => {
      S.taskReducer(self.state, task, ~dispatchAction=dispatchAction(self))
    }, 0)->ignore

  let getState = self => self.state
}

module Manager = MakeManager(GlobalState)
include Manager
