type t = {logger: Pino.t, exn: exn, msg: option<string>}

let make = (exn, ~logger=Logging.getLogger(), ~msg=?) => {
  {logger, msg, exn}
}

let log = (self: t) => {
  switch self {
  | {exn, msg: Some(msg), logger} => logger->Logging.childErrorWithExn(exn->Utils.prettifyExn, msg)
  | {exn, msg: None, logger} => logger->Logging.childError(exn->Utils.prettifyExn)
  }
}

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

let raiseExn = (self: t) => {
  self->toExn->throw
}

let mkLogAndRaise = (~logger=?, ~msg=?, exn) => {
  let self = exn->Utils.prettifyExn->make(~logger?, ~msg?)
  self->log
  self->raiseExn
}

let unwrapLogAndRaise = (~logger=?, ~msg=?, result) => {
  switch result {
  | Ok(v) => v
  | Error(exn) => exn->mkLogAndRaise(~logger?, ~msg?)
  }
}

let logAndRaise = self => {
  self->log
  self->raiseExn
}
