// What `defineSidecar` builds (contract.ts): every input already wrapped with
// `S.schema`.
type functionDef = {input: S.t<unknown>}
type t = {functions: dict<functionDef>}

// The slot `defineSidecar` writes. A symbol key, so no field access to type.
let current: unit => option<t> = %raw(`() => globalThis[Symbol.for("envio.sidecarContract")]`)

// Importing the contract module is what fills the slot. Skipped when it's
// already filled, which is how a test that imports its contract itself runs
// without one on disk.
let loadOrThrow = async (~config: Config.t) =>
  switch (config.sidecar, current()) {
  | (None, _) | (Some(_), Some(_)) => ()
  | (Some({contract}), None) =>
    try {
      let _ = await Utils.importPath(
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
    if current()->Option.isNone {
      JsError.throwWithMessage(
        `The sidecar contract '${contract}' must default-export defineSidecar({ functions }): \`export default defineSidecar(...)\`.`,
      )
    }
  }
