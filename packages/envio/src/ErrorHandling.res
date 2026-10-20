type t = {logger: Logger.t, exn: exn, msg: option<string>}

let make = (exn, ~logger, ~msg=?) => {logger, msg, exn}

let log = ({logger, exn, msg}: t) =>
  logger->Logger.errorWithExn(
    switch msg {
    | Some(msg) => msg
    | None => exn->Utils.exnMessage->Option.getOr("Unexpected error")
    },
    exn,
  )

// The exception to hand to whoever is outside the indexer. A failure raised
// from a message alone carries no exception of its own, so rethrowing or
// rejecting with `exn` would hand over a bare `null` and the reason would live
// only in the logs. Fall back to the message, which is the whole of what such a
// failure knows.
let toExn = (self: t) =>
  switch self.exn->(Utils.magic: exn => Nullable.t<exn>)->Nullable.toOption {
  | Some(exn) => exn->Utils.prettifyExn
  | None => Utils.Error.make(self.msg->Option.getOr("Indexer has failed with an unexpected error"))
  }

let mkLogAndRaise = (~logger, ~msg=?, exn) => {
  let self = exn->make(~logger, ~msg?)
  self->log
  self->toExn->throw
}
