type t = {logger: Pino.t, exn: exn, msg: option<string>}

let make = (exn, ~logger=Logging.getLogger(), ~msg=?) => {
  {logger, msg, exn}
}

let log = (self: t) => {
  // Log as a single-line string so pino-pretty doesn't render the
  // `err: { type, message, stack, ... }` block beneath the message.
  let exnMessage = switch self.exn->JsExn.anyToExnInternal {
  | JsExn(e) => e->JsExn.message->Option.getOr("")
  | _ => ""
  }
  let finalMsg = switch (self.msg, exnMessage) {
  | (Some(msg), "") => msg
  | (None, "") => "Unknown error"
  | (_, exnMsg) => exnMsg
  }
  self.logger->Logging.childError(finalMsg)
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
