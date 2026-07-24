// The single process-wide mutable state record, stashed on `globalThis` so a
// duplicate envio module instance — e.g. when the CLI's `bin.mjs` resolves
// envio from one path but the user's handlers resolve it from
// `node_modules/envio` — shares one state. Without this, each copy keeps its
// own module-level state: registration would read an empty registry and the
// `indexer.chains` getters would silently fall back to static config values.
//
// Slots are opaque (`unknown`) so this module stays at the bottom of the
// dependency graph; each owning module casts its slot to the real type once
// (`HandlerRegister` for the registration slots, `Main` for the runtime
// slots, `RollbackCommit` for its callbacks).
//
// Version-gated: the slot shapes can evolve between envio versions, so the
// guard uses strict full-version equality. On mismatch we throw with a
// deduplication hint instead of silently mixing shapes across builds.
type t = {
  version: string,
  mutable activeRegistration: option<unknown>,
  // When set, registration and `indexer` getters resolve against this scope
  // instead of `activeRegistration`. Used by the internal test indexer to run
  // an isolated handler set per instance without touching the global registry.
  mutable registrationScopeOverride: option<unknown>,
  preRegistered: array<unknown>,
  rollbackCommitCallbacks: array<unknown>,
  mutable indexerState: option<unknown>,
  mutable persistence: option<unknown>,
}

// Record type with `mutable` so assignment typechecks; ReScript keeps the
// field name verbatim in the generated JS so the globalThis slot is
// `__envioGlobal`.
type globalThis = {mutable __envioGlobal: Nullable.t<t>}
@val external globalThis: globalThis = "globalThis"

let value: t = {
  let version = Utils.EnvioPackage.value.version
  switch globalThis.__envioGlobal->Nullable.toOption {
  | Some(existing) if existing.version === version => existing
  | Some(existing) =>
    JsError.throwWithMessage(
      `Multiple incompatible envio versions loaded in the same process: ${existing.version} and ${version}. Deduplicate the 'envio' dependency in your project.`,
    )
  | None =>
    let fresh = {
      version,
      activeRegistration: None,
      registrationScopeOverride: None,
      preRegistered: [],
      rollbackCommitCallbacks: [],
      indexerState: None,
      persistence: None,
    }
    globalThis.__envioGlobal = Nullable.make(fresh)
    fresh
  }
}
