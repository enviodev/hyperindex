type chainConfig = {
  id: int,
  startBlock: int,
  endBlock: option<int>,
}

type ecosystemConfig = {chains: dict<chainConfig>}

type t = {
  name: string,
  description: option<string>,
  evm: option<ecosystemConfig>,
  fuel: option<ecosystemConfig>,
  svm: option<ecosystemConfig>,
}

let chainConfigSchema = S.object(s => {
  id: s.field("id", S.int),
  startBlock: s.field("startBlock", S.int),
  endBlock: s.field("endBlock", S.option(S.int)),
})

let ecosystemConfigSchema = S.schema(s => {
  chains: s.matches(S.dict(chainConfigSchema)),
})

let rawSchema = S.schema(s => {
  name: s.matches(S.string),
  description: s.matches(S.option(S.string)),
  evm: s.matches(S.option(ecosystemConfigSchema)),
  fuel: s.matches(S.option(ecosystemConfigSchema)),
  svm: s.matches(S.option(ecosystemConfigSchema)),
})

let parseOrThrow = (json: Js.Json.t): t => {
  try json->S.parseOrThrow(rawSchema) catch {
  | S.Raised(exn) =>
    Js.Exn.raiseError(`Invalid internal.config.ts: ${exn->Utils.prettifyExn->Utils.magic}`)
  }
}
