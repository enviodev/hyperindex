type t = {logger: Pino.t, exn: exn, msg: option<string>}

let prettifyExn = exn => {
  switch exn->Js.Exn.anyToExnInternal {
  | Js.Exn.Error(e) => e->(Utils.magic: Js.Exn.t => exn)
  | exn => exn
  }
}

let make = (exn, ~logger=Logging.logger, ~msg=?) => {
  {logger, msg, exn}
}

let log = (self: t) => {
  switch self {
  | {exn, msg: Some(msg), logger} => logger->Logging.childErrorWithExn(exn->prettifyExn, msg)
  | {exn, msg: None, logger} => logger->Logging.childError(exn->prettifyExn)
  }
}

let raiseExn = (self: t) => {
  self.exn->prettifyExn->raise
}

let mkLogAndRaise = (~logger=?, ~msg=?, exn) => {
  let exn = exn->prettifyExn
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
