// Type-checks handler source against a config's generated `indexer` surface.
// Lives in TypeScript (`TypeChecker.ts`) since it drives the TS compiler API.
@module("./TypeChecker.ts")
external checkHandlerTypes: (string, string) => array<string> = "checkHandlerTypes"

type parsed = {
  config: Config.t,
  publicConfigJson: JSON.t,
}

// Parse the same YAML a user supplies, then cross the public JSON boundary used at runtime.
// When `handlers` (TS source using `import {indexer} from "envio"`) is supplied, it's
// type-checked against the config's generated types and any type error is thrown.
let parseYaml = (~schema=?, ~env=?, ~files=?, ~handlers=?, ~isRescript=false, yaml): parsed => {
  let publicConfigJson =
    Core.parseConfigYaml(~schema?, ~env?, ~files?, ~isRescript, yaml)->JSON.parseOrThrow

  switch handlers {
  | Some(handlers) =>
    let typesDts = Core.generateIndexerTypes(~schema?, ~env?, ~files?, yaml)
    switch checkHandlerTypes(typesDts, handlers) {
    | [] => ()
    | errors => JsError.throwWithMessage("Handler type errors:\n" ++ errors->Array.join("\n"))
    }
  | None => ()
  }

  {
    publicConfigJson,
    config: Config.fromPublic(publicConfigJson),
  }
}
