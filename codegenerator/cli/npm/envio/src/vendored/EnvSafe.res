// Vendored from rescript-envsafe v5.0.0, adapted for sury (ReScript 12)
// Original: https://github.com/DZakh/rescript-envsafe

%%private(external magic: 'a => 'b = "%identity")

module Stdlib = {
  module Dict = {
    @get_index external get: (dict<'a>, string) => option<'a> = ""
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

    let raiseError = (error: error): 'a => error->(magic: error => exn)->throw
  }
}

module Error = {
  @inline
  let panic = message => Stdlib.Exn.raiseError(Stdlib.Exn.makeError(`[EnvSafe] ${message}`))
}

type env = dict<string>
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
  external default: dict<string> = "process.env"
}

let mixinMissingIssue = (envSafe, issue) => {
  switch envSafe.maybeMissingIssues {
  | Some(missingIssues) => missingIssues->Array.push(issue)
  | None => envSafe.maybeMissingIssues = Some([issue])
  }
}

let mixinInvalidIssue = (envSafe, issue: invalidIssue) => {
  switch envSafe.maybeInvalidIssues {
  | Some(invalidIssues) => invalidIssues->Array.push(issue)
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
          output->Array.push("❌ Invalid environment variables:")
          invalidIssues->Array.forEach(issue => {
            output->Array.push(`    ${issue.name}: ${issue.error.message}`)
          })
        })

        maybeMissingIssues->Stdlib.Option.forEach(missingIssues => {
          output->Array.push("💨 Missing environment variables:")
          missingIssues->Array.forEach(issue => {
            output->Array.push(
              `    ${issue.name}: ${switch issue.input {
                | Some("") => "Disallowed empty string"
                | _ => "Missing value"
                }}`,
            )
          })
        })

        output->Array.push(line)
        output->Array.join("\n")
      }

      Console.error(text)
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
  if Float.isNaN(float) {
    string
  } else {
    float->magic
  }
}

let bigintCoerce = string => {
  try BigInt.fromStringOrThrow(string)->magic catch {
  | _ => string
  }
}

let jsonCoerce = string => {
  try JSON.parseExn(string)->magic catch {
  | _ => string
  }
}

// Get the tag of a schema's inner type (unwrapping option/union if needed)
let getInnerTag = (schema: S.t<'a>): S.tag => {
  let untagged = schema->(magic: S.t<'a> => S.t<unknown>)->S.untag
  switch untagged.tag {
  | Union => {
      // For S.option(x), sury creates a union. Find the first non-undefined member tag.
      let anyOf: array<S.t<unknown>> = (untagged->(magic: S.untagged => {..}))["anyOf"]
      let innerTag =
        anyOf->Array.find(s => S.untag(s).tag != Undefined)->Option.map(s => S.untag(s).tag)
      switch innerTag {
      | Some(tag) => tag
      | None => Union
      }
    }
  | tag => tag
  }
}

// Check if a schema is optional (accepts undefined/None)
let isOptionalSchema = (schema: S.t<'a>): bool => {
  let untagged = schema->(magic: S.t<'a> => S.t<unknown>)->S.untag
  switch untagged.tag {
  | Union => {
      let anyOf: array<S.t<unknown>> = (untagged->(magic: S.untagged => {..}))["anyOf"]
      anyOf->Array.some(s => S.untag(s).tag == Undefined)
    }
  | _ => false
  }
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
  let isOptional = isOptionalSchema(schema)
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
    let innerTag = getInnerTag(schema)
    let input = switch input {
    | Some("") if !allowEmpty => None
    | None => None
    | Some(string) =>
      switch innerTag {
      | Boolean => string->boolCoerce
      | BigInt => string->bigintCoerce
      | Number => string->numberCoerce
      | String | Never => string
      | Union => {
          // For union schemas, try coercions in order: bool, number, bigint, then keep as string
          let coerced = boolCoerce(string)
          if coerced !== string->(magic: string => 'a) {
            coerced
          } else {
            let coerced = numberCoerce(string)
            if coerced !== string->(magic: string => 'a) {
              coerced
            } else {
              let coerced = bigintCoerce(string)
              if coerced !== string->(magic: string => 'a) {
                coerced
              } else {
                jsonCoerce(string)
              }
            }
          }
        }
      | _ => string->jsonCoerce
      }->Some
    }
    try input->S.parseOrThrow(schema) catch {
    | S.Error(error) => {
        envSafe->mixinInvalidIssue({name, error, input})
        %raw(`undefined`)
      }
    }
  }
}
