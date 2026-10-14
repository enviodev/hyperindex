// What `defineSidecar` builds (contract.ts): every input already wrapped with
// `S.schema`.
type functionDef = {input: S.t<unknown>}
type webhookDef = {body: S.t<unknown>}
type t = {functions: dict<functionDef>, webhooks?: dict<webhookDef>}

let webhookBodySchema = (contract: t, ~name) =>
  contract.webhooks->Option.flatMap(webhooks => webhooks->Utils.Dict.dangerouslyGetNonOption(name))

let current: ref<option<t>> = ref(None)
// The test harness binds a fixture's contract itself, since the path its
// config names is not on disk; `loadOrThrow` then leaves it alone.
let isSetByHarness = ref(false)

let get = () => current.contents

let set = (contract: t) => {
  current := Some(contract)
  isSetByHarness := true
}

let asContract = (value: unknown): option<t> =>
  if (
    typeof(value) === #object &&
    !(value->(Utils.magic: unknown => Nullable.t<unknown>)->Nullable.isNullable) &&
    (value->(Utils.magic: unknown => {"kind": unknown}))["kind"] ===
      "envio.sidecarContract"->(Utils.magic: string => unknown)
  ) {
    Some(value->(Utils.magic: unknown => t))
  } else {
    None
  }

// The default export, or `default.default` when an ES import reaches a
// CommonJS build of the module (`exports.default = defineSidecar(...)`).
let fromModuleOrThrow = (moduleExports: unknown, ~path) => {
  let default = (moduleExports->(Utils.magic: unknown => {"default": unknown}))["default"]
  switch default->asContract {
  | Some(contract) => contract
  | None =>
    switch default
    ->(Utils.magic: unknown => Nullable.t<{"default": unknown}>)
    ->Nullable.toOption
    ->Option.flatMap(nested => nested["default"]->asContract) {
    | Some(contract) => contract
    | None =>
      JsError.throwWithMessage(
        `The sidecar contract '${path}' must default-export defineSidecar({ functions }): \`export default defineSidecar(...)\`.`,
      )
    }
  }
}

let loadOrThrow = async (~config: Config.t) =>
  if !isSetByHarness.contents {
    current :=
      switch config.sidecar {
      | None => None
      | Some({contract}) =>
        let moduleExports = try {
          await Utils.importPath(
            NodeJs.Path.resolve([NodeJs.Process.cwd(), contract])
            ->NodeJs.Path.toString
            ->NodeJs.Url.pathToFileURL
            ->NodeJs.Url.toString,
          )
        } catch {
        | exn =>
          JsError.throwWithMessage(
            `Failed to load the sidecar contract '${contract}' named by \`sidecar.contract\`. Cause: ${exn
              ->Utils.prettifyExn
              ->Obj.magic}`,
          )
        }
        Some(moduleExports->fromModuleOrThrow(~path=contract))
      }
  }
