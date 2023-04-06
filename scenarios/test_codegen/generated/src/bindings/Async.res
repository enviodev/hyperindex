module Queue = {
  type t<'a> = 'a

  type task<'a> = 'a
  type errorMessage = string
  type callback = option<errorMessage> => unit
  type worker<'a> = (~task: task<'a>, ~callback: callback) => unit
  type concurrency = int

  @module("async")
  external make: (~worker: worker<'a>, ~concurrency: concurrency=?, unit) => t<'a> = "queue"

  @ocaml.doc(
    "add a new task to the queue. Calls callback once the worker has finished processing the task."
  )
  @send
  external push: (t<'a>, ~task: task<'a>, ~callback: callback=?, unit) => unit = "push"

  @ocaml.doc(
    "Instead of a single task, a tasks array can be submitted. The respective callback is used for every task in the list."
  )
  @send
  external pushMultiple: (t<'a>, ~task: array<task<'a>>, ~callback: callback=?, unit) => unit =
    "push"

  @ocaml.doc("add a new task to the front of the queue") @send
  external unshift: (t<'a>, ~task: task<'a>, ~callback: callback=?, unit) => unit = "unshift"

  @ocaml.doc("the same as push, except this returns a promise that rejects if an error occurs.")
  @send
  external pushAsync: (t<'a>, ~task: task<'a>) => Promise.t<unit> = "pushAsync"

  @ocaml.doc("the same as unshift, except this returns a promise that rejects if an error occurs.")
  @send
  external unshiftAsync: (t<'a>, ~task: task<'a>, ~callback: callback=?, unit) => Promise.t<unit> =
    "unshiftAsync"

  @ocaml.doc("A function returning the number of items waiting to be processed") @send
  external length: t<'a> => int = "length"

  @ocaml.doc(
    "a boolean indicating whether or not any items have been pushed and processed by the queue."
  )
  @get
  external started: t<'a> => bool = "started"

  @ocaml.doc("a function returning the number of items currently being processed") @send
  external running: t<'a> => int = "running"

  @ocaml.doc(
    "a function that sets a callback that is called when the last item from the queue has returned from the worker."
  )
  @send
  external drain: (t<'a>, callback) => unit = "drain"

  @send
  external error: (t<'a>, callback) => unit = "error"
}
