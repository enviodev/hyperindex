type exnType = Js(Js.Exn.t) | Other(exn)

type t = {logger: Pino.t, exn: exnType, msg: option<string>}

let makeExnType = (exn): exnType => {
  switch exn {
  | Js.Exn.Error(e)
  | Promise.JsError(e) =>
    Js(e)
  | exn => Other(exn)
  }
}

let make = (~logger=Logging.logger, ~msg=?, exn) => {
  {logger, msg, exn: exn->makeExnType}
}

let log = (self: t) => {
  switch self {
  | {exn: Js(e), msg: Some(msg), logger} => logger->Logging.childErrorWithJsExn(e, msg)
  | {exn: Js(e), msg: None, logger} => logger->Logging.childError(e)
  | {exn: Other(e), msg: Some(msg), logger} => logger->Logging.childErrorWithExn(e, msg)
  | {exn: Other(e), msg: None, logger} => logger->Logging.childError(e)
  }
}

exception JsExnError(Js.Exn.t)
let getExn = (self: t) => {
  switch self.exn {
  | Other(exn) => exn
  | Js(e) => JsExnError(e)
  }
}

let raiseExn = (self: t) => {
  self->getExn->raise
}
