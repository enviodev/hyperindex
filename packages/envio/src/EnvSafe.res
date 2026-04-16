@@uncurried

%%private(external magic: 'a => 'b = "%identity")

module Stdlib = {
  module Dict = {
    @get_index external get: (Js.Dict.t<'a>, string) => option<'a> = ""
  }

  module Option = {
    @inline
    let forEach = (option, fn) => {
      switch option {
      | Some(v) => fn(v)
      | None => ()
      }
    }
  }

  module Window = {
    let alert = (message: string): unit => {
      message->ignore
      if %raw(`typeof window !== 'undefined' && window.alert`) {
        %raw(`window.alert(message)`)
      }
    }
  }

  module Exn = {
    type error

    @new
    external makeError: string => error = "Error"
    @new
    external makeTypeError: string => error = "TypeError"

    let raiseError = (error: error): 'a => error->magic->raise
  }
}

module Error = {
  @inline
  let panic = message =>
    Stdlib.Exn.raiseError(Stdlib.Exn.makeError(`[rescript-envsafe] ${message}`))
}

type env = Js.Dict.t<string>
type invalidIssue = {name: string, error: S.error, input: option<string>}
type missingIssue = {name: string, input: option<string>}
type t = {
  env: env,
  mutable isLocked: bool,
  mutable maybeMissingIssues: option<array<missingIssue>>,
  mutable maybeInvalidIssues: option<array<invalidIssue>>,
}

module Env = {
  @val
  external // FIXME: process might be missing
  default: Js.Dict.t<string> = "process.env"
}

let mixinMissingIssue = (envSafe, issue) => {
  switch envSafe.maybeMissingIssues {
  | Some(missingIssues) => missingIssues->Js.Array2.push(issue)->ignore
  | None => envSafe.maybeMissingIssues = Some([issue])
  }
}

let mixinInvalidIssue = (envSafe, issue: invalidIssue) => {
  switch envSafe.maybeInvalidIssues {
  | Some(invalidIssues) => invalidIssues->Js.Array2.push(issue)->ignore
  | None => envSafe.maybeInvalidIssues = Some([issue])
  }
}

let make = (~env=Env.default) => {
  {env, isLocked: false, maybeMissingIssues: None, maybeInvalidIssues: None}
}

let close = envSafe => {
  if envSafe.isLocked {
    Error.panic("EnvSafe is already closed.")
  }
  envSafe.isLocked = true
  switch (envSafe.maybeMissingIssues, envSafe.maybeInvalidIssues) {
  | (None, None) => ()
  | (maybeMissingIssues, maybeInvalidIssues) => {
      let text = {
        let line = "========================================"
        let output = [line]

        maybeInvalidIssues->Stdlib.Option.forEach(invalidIssues => {
          output->Js.Array2.push("❌ Invalid environment variables:")->ignore
          invalidIssues->Js.Array2.forEach(issue => {
            output->Js.Array2.push(`    ${issue.name}: ${issue.error->S.Error.message}`)->ignore
          })
        })

        maybeMissingIssues->Stdlib.Option.forEach(missingIssues => {
          output->Js.Array2.push("💨 Missing environment variables:")->ignore
          missingIssues->Js.Array2.forEach(issue => {
            output
            ->Js.Array2.push(
              `    ${issue.name}: ${switch issue.input {
                | Some("") => "Disallowed empty string"
                | _ => "Missing value"
                }}`,
            )
            ->ignore
          })
        })

        output->Js.Array2.push(line)->ignore
        output->Js.Array2.joinWith("\n")
      }

      Js.Console.error(text)
      Stdlib.Window.alert(text)
      Stdlib.Exn.raiseError(Stdlib.Exn.makeTypeError(text))
    }
  }
}

let boolCoerce = string =>
  switch string {
  | "true"
  | "t"
  | "1" =>
    true->magic
  | "false"
  | "f"
  | "0" =>
    false->magic
  | _ => string
  }

let numberCoerce = string => {
  let float = %raw(`+string`)
  if Js.Float.isNaN(float) {
    string
  } else {
    float->magic
  }
}

let bigintCoerce = string => {
  try string->Js.BigInt.fromStringExn->magic catch {
  | _ => string
  }
}

let jsonCoerce = string => {
  try string->Js.Json.parseExn->magic catch {
  | _ => string
  }
}

@inline
let prepareUnionSchemaCoercion = schema => {
  schema->S.preprocess(s => {
    let tagged = switch s.schema->S.classify {
    | Option(optionalSchema) => optionalSchema->S.classify
    | tagged => tagged
    }
    switch tagged {
    | Literal(Boolean(_))
    | Bool => {
        parser: unknown => unknown->magic->boolCoerce->magic,
      }
    | Literal(BigInt(_))
    | BigInt => {
        parser: unknown => unknown->magic->bigintCoerce->magic,
      }
    | Literal(Number(_))
    | Int
    | Float => {
        parser: unknown => unknown->magic->numberCoerce->magic,
      }
    | String
    | Literal(String(_))
    | Union(_)
    | Never => {}
    | _ => {
        parser: unknown => unknown->magic->jsonCoerce->magic,
      }
    }
  })
}

let get = (
  envSafe,
  name,
  schema,
  ~allowEmpty=false,
  ~fallback as maybeFallback=?,
  ~devFallback as maybeDevFallback=?,
  ~input as maybeInlinedInput=?,
) => {
  if envSafe.isLocked {
    Error.panic("EnvSafe is closed. Make a new one to get access to environment variables.")
  }
  let input = switch maybeInlinedInput {
  | Some(inlinedInput) => inlinedInput
  | None => envSafe.env->Stdlib.Dict.get(name)
  }
  let isMissing = switch (input, allowEmpty) {
  | (None, _)
  | (Some(""), false) => true
  | _ => false
  }
  let isOptional = switch schema->S.classify {
  | Option(_) => true
  | _ => false
  }
  if isMissing && !isOptional {
    switch (maybeDevFallback, maybeFallback) {
    | (Some(devFallback), _)
      if envSafe.env->Stdlib.Dict.get("NODE_ENV") !== Some("production") => devFallback
    | (_, Some(fallback)) => fallback
    | _ => {
        envSafe->mixinMissingIssue({name, input})
        %raw(`undefined`)
      }
    }
  } else {
    let tagged = switch schema->S.classify {
    | Option(optionalSchema) => optionalSchema->S.classify
    | tagged => tagged
    }
    let input = switch input {
    | Some("") if !allowEmpty => None
    | None => None
    | Some(string) =>
      switch tagged {
      | Literal(Boolean(_))
      | Bool =>
        string->boolCoerce
      | Literal(BigInt(_))
      | BigInt =>
        string->bigintCoerce
      | Literal(Number(_))
      | Int
      | Float =>
        string->numberCoerce
      | String
      | Literal(String(_))
      | Never
      | Union(_) => string
      | _ => string->jsonCoerce
      }->Some
    }
    let schema = switch tagged {
    | Union(_) => prepareUnionSchemaCoercion(schema)
    | _ => schema
    }
    try input->S.parseOrThrow(schema) catch {
    | S.Raised(error) => {
        envSafe->mixinInvalidIssue({name, error, input})
        %raw(`undefined`)
      }
    }
  }
}
