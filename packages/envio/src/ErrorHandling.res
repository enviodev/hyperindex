type t = {logger: Pino.t, exn: exn, msg: option<string>, params: option<Internal.logParams>}

let make = (exn, ~logger: Pino.t, ~msg=?, ~params=?) => {
  {logger, msg, exn, params: params->Option.map(Internal.toLogParams)}
}

// Params are merged into the logged object rather than bound to a child
// logger, so a single logger instance can serve every context.
let withParams = (message: 'a, params) =>
  switch params {
  | Some(params) =>
    Utils.Dict.merge(
      params->(Utils.magic: Internal.logParams => dict<unknown>),
      message->(Utils.magic: 'a => dict<unknown>),
    )->(Utils.magic: dict<unknown> => 'a)
  | None => message
  }

let log = (self: t) => {
  let {exn, msg, logger, params} = self
  let err = exn->Utils.prettifyExn
  switch (msg, params) {
  | (Some(msg), None) => logger->Logging.errorWithExn(err, msg)
  | (None, None) => logger->Logging.error(err)
  | (_, Some(_)) => logger->Logging.error({"msg": msg, "err": err}->withParams(params))
  }
}

let raiseExn = (self: t) => {
  self.exn->Utils.prettifyExn->throw
}

let mkLogAndRaise = (~logger, ~msg=?, ~params=?, exn) => {
  let exn = exn->Utils.prettifyExn
  exn->make(~logger, ~msg?, ~params?)->log
  exn->throw
}

let unwrapLogAndRaise = (~logger, ~msg=?, ~params=?, result) => {
  switch result {
  | Ok(v) => v
  | Error(exn) => exn->mkLogAndRaise(~logger, ~msg?, ~params?)
  }
}

let logAndRaise = self => {
  self->log
  self->raiseExn
}
