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
  | {exn: Js(e), msg: Some(msg), logger} => logger->Logging.childErrorWithExn(e, msg)
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

let mkLogAndRaise = (~logger=?, ~msg=?, exn) => {
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

/**
An environment to manage control flow propogating results 
with Error that contain ErrorHandling.t in async
contexts and avoid nested switch statements on awaited promises
Similar to rust result propogation
*/
module ResultPropogateEnv = {
  exception ErrorHandlingEarlyReturn(t)

  type resultWithErrorHandle<'a> = result<'a, t>
  type asyncBody<'a> = unit => promise<resultWithErrorHandle<'a>>

  let runAsyncEnv = async (body: asyncBody<'a>) => {
    switch await body() {
    | exception ErrorHandlingEarlyReturn(e) => Error(e)
    | endReturn => endReturn
    }
  }

  let propogate = (res: resultWithErrorHandle<'a>) =>
    switch res {
    | Ok(v) => v
    | Error(e) => raise(ErrorHandlingEarlyReturn(e))
    }
}
