// Type-checks handler source against a config's generated `indexer` surface.
// Lives in TypeScript (`TypeChecker.ts`) since it drives the TS compiler API.
@module("./TypeChecker.ts")
external checkHandlerTypes: (string, string) => array<string> = "checkHandlerTypes"

type parsed = {
  config: Config.t,
  publicConfigJson: JSON.t,
}

// Parse the same YAML a user supplies, then cross the public JSON boundary used at runtime.
// When `handlers` (TS source using `import {indexer} from "envio"`) is supplied, the same
// parse also emits the generated types, and the handlers are type-checked against them;
// any type error is thrown.
let fromUserApi = (~schema=?, ~env=?, ~files=?, ~handlers=?, ~configYaml): parsed => {
  let {config: configJson, indexerTypes} =
    Core.fromUserApi(~schema?, ~env?, ~files?, ~withIndexerTypes=handlers->Option.isSome, configYaml)

  switch (handlers, indexerTypes->Null.toOption) {
  | (Some(handlers), Some(typesDts)) =>
    switch checkHandlerTypes(typesDts, handlers) {
    | [] => ()
    | errors => JsError.throwWithMessage("Handler type errors:\n" ++ errors->Array.join("\n"))
    }
  | _ => ()
  }

  let publicConfigJson = configJson->JSON.parseOrThrow
  {
    publicConfigJson,
    config: Config.fromPublic(publicConfigJson),
  }
}
