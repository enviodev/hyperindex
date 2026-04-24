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

let raiseExn = (self: t) => {
  self.exn->Utils.prettifyExn->throw
}

let mkLogAndRaise = (~logger=?, ~msg=?, exn) => {
  let exn = exn->Utils.prettifyExn
  exn->make(~logger?, ~msg?)->log
  exn->throw
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
