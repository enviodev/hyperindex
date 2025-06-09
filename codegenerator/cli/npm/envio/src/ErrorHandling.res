type t = {logger: Pino.t, exn: exn, msg: option<string>}

let make = (exn, ~logger=Logging.getLogger(), ~msg=?) => {
  {logger, msg, exn}
}

let log = (self: t) => {
  switch self {
  | {exn, msg: Some(msg), logger} =>
    logger->Logging.childErrorWithExn(exn->Internal.prettifyExn, msg)
  | {exn, msg: None, logger} => logger->Logging.childError(exn->Internal.prettifyExn)
  }
}

let raiseExn = (self: t) => {
  self.exn->Internal.prettifyExn->raise
}

let mkLogAndRaise = (~logger=?, ~msg=?, exn) => {
  let exn = exn->Internal.prettifyExn
  exn->make(~logger?, ~msg?)->log
  exn->raise
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
