- Never delete comments describing unobvious logic when refactoring. Move or update them to match the new code, but preserve their intent.
- Use `pnpm` over `npm`/`npx`.
- Always use single assert to check the whole value instead of multiple asserts for every field.

## Plan Mode

- Make the plan extremely concise. Sacrifice grammar for the sake of concision.
- At the end of each plan, give me a list of unresolved questions to answer, if any.
- Finish every plan by running tests.

## Navigation

- The Rust CLI lives in `packages/cli`.
  - Entry point: `packages/cli/src/lib.rs`.
  - Command dispatcher: `packages/cli/src/commands.rs`.
- Config parsing pipeline:
  - `human_config.rs` → reads user files & JSON schemas.
  - `system_config.rs` → converts to internal structs.
  - `hbs_templating/codegen_templates.rs` → feeds templates.
- Templates live under `packages/cli/templates`:
  - `dynamic/` – Handlebars (.hbs)
  - `static/` – raw Rescript files copied verbatim.
- Generated runtime (inside each project's `generated/`):
  - Entry module: `Index.res` (starts HTTP server, loads `Config.res`, calls `RegisterHandlers.res`, spins up `GlobalStateManager.res`).
  - Config: `Config.res` (env → typed config, sets up persistence).
  - Persistence stack: `PgStorage.res`, `Hasura.res`, `Persistence.res`, `IO.res`.
  - Fetch side: `ChainManager.res`, `ChainFetcher.res`, `FetchState.res`, `SourceManager.res`.
  - Processing: `GlobalStateManager.res`, `EventProcessing.res`, `IO.res`.
  - Metrics: `Prometheus.res`.
- Library-fied runtime shared across indexers lives in `packages/envio`.
  - ReScript sources compile with `pnpm rescript -w` for live reload.
- Start with module names (e.g., `Index.res`, `ChainManager.res`) and let fuzzy search resolve paths.
- Runtime code lives in each project's `generated/src`, but template versions (good for editing) are under `packages/cli/templates/static/codegen/src` or `packages/cli/templates/dynamic/codegen/src`.
- Config parsing & codegen lives in Rust. When tracking how a value reaches templates, follow `human_config.rs` → `system_config.rs` → `codegen_templates.rs`.
- Prefer reading ReScript `.res` modules directly; compiled `.js` artifacts can be ignored.

## Testing

Prefer Public module API for testing.

Verify that tests pass by running a compiler `pnpm rescript` and tests `pnpm mocha`. Use `_only` to specify which tests to run.

## ReScript

- When using `Utils.magic` for type casting, always add explicit type annotations: `value->(Utils.magic: inputType => outputType)`
- Always use ReScript 11 documentation.
- Never suggest ReasonML syntax.
- Never use `[| item |]` to create an array. Use `[ item ]` instead.
- Must always use `=` for setting value to a field. Use `:=` only for ref values created using `ref` function.
- Never use %raw to access object fields if you know the type.
- Never use `Js.Console.log` in test files. Use `Assert` module for all verifications.
- Tests should be silent unless they fail — rely on assertions rather than logging.
- Use try/catch as expressions instead of refs for tracking success/failure.
