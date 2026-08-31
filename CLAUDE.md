- Use `pnpm` over `npm`/`npx`.
- Always use single assert to check the whole value instead of multiple asserts for every field.

## Comments

- Default to writing no comments. A comment earns its place only when it explains something the code itself cannot show.
- Write a comment when it captures: a non-obvious constraint, a subtle invariant, a workaround for a specific bug, or behavior that would surprise a reader.
- Don't write a comment that restates what the code already says — module purpose, what a function does, which callers use a value, history of a refactor, or pointers to where something is "now defined".
- Never narrate the refactor itself ("previously lived in X", "centralized here", "now imports from Y"). That belongs in the commit message, not the code.
- When refactoring, keep comments that still explain non-obvious behavior; drop or rewrite comments that described the old shape.

## Plan Mode

- Make the plan extremely concise. Sacrifice grammar for the sake of concision.
- At the end of each plan, give me a list of unresolved questions to answer, if any.
- Finish every plan by running tests.

## Navigation

- Rust CLI: `packages/cli`, entry at `lib.rs`, commands at `commands.rs`.
- Config parsing pipeline: `human_config.rs` → `system_config.rs` → internal JSON → `hbs_templating/codegen_templates.rs` → `Config.res`.
- Shared runtime library: `packages/envio`. Its tests: `packages/envio-tests`.
- Scenario projects: `scenarios/` — `test_codegen`, `e2e_test`, `fuel_test`, `svm_test`.
- To edit runtime code, edit templates under `packages/cli/templates/` or `packages/envio/`, not the codegen output under `<project>/.envio/`.
- Prefer reading `.res` modules directly; ignore compiled `.js` artifacts.
- The napi boundary between the Rust addon (`#[napi]` exports) and ReScript (`Core.addon`) is internal, not a published API. Change both sides freely to get the better shape — don't keep an awkward export for compatibility. The addon must be rebuilt for ReScript tests to see the change (see below).

### Building the native addon

ReScript tests call into the Rust addon, so a Rust change needs a rebuild before they see it:

```
SVM_TARGET_PLATFORM=linux-amd64 cargo build --lib
mkdir -p node_modules/envio-linux-x64
cp target/debug/libenvio.so node_modules/envio-linux-x64/envio.node
printf '{"name":"envio-linux-x64","version":"0.0.1-dev","main":"envio.node"}\n' > node_modules/envio-linux-x64/package.json
```

`Core.loadAddon` resolves the platform package by name, which is why the debug build is staged into `node_modules` rather than loaded from `target/`.

## Storage

- No in-place migrations and no dynamic chain addition: on schema or config changes the user is expected to resync from scratch. Don't design or propose migration paths for existing deployments.

## Testing and Development

Every change starts with a failing reproduction — bug fix, review finding, or new feature. Write it before touching the source, watch it fail, then fix. No change without one.

Reproduce from the outside in — real `config.yaml`, real `schema.graphql`, real handler source. Never reach into an internal module to trigger a bug. If it can't be reached from the outside, that's the finding: say so before writing a fix.

Pick the highest rung that reproduces:

1. **User API** — `packages/envio-tests`, via `InternalTestIndexer.fromUserApi(~configYaml, ~schema, ~handlers, ~test)`. User YAML, schema and handler source, type-checked and executed, with `createTestIndexer()` in the test. No codegen, no database. See `TokenIndexer_test.res`. Default — start here.
   `cd packages/envio-tests && pnpm rescript && pnpm vitest run -t "name"`
2. **Mock indexer** — `scenarios/test_codegen`, via `test/helpers/MockIndexer.res`. Real indexer loop over the generated config with `Source` and `Storage` mocked, Postgres included. Use when the bug is in the loop itself: fetching, reorgs, batching, writes. The config can still come from `fromUserApi` — see `YamlConfigIndexer_test.res`.
   `cd scenarios/test_codegen && pnpm exec envio codegen && pnpm rescript && pnpm vitest run test/X_test.res`
3. **End to end** — `scenarios/e2e_test`. For what the rungs above can't mock: ClickHouse, Hasura, and the CLI itself. CI runs it against real services, so anything beyond the local smoke test lands here.
   `cd scenarios/e2e_test && pnpm exec envio codegen && pnpm test`

Link the issue above the case when there is one: `// https://github.com/enviodev/hyperindex/issues/N`

Run only the tests relevant to your change — never the full suite locally. CI runs it on push.

## ReScript

- When using `Utils.magic` for type casting, always add explicit type annotations: `value->(Utils.magic: inputType => outputType)`
- Always use ReScript 12 documentation. Never suggest ReasonML syntax.
- Never use `[| item |]` to create an array. Use `[ item ]` instead.
- Must always use `=` for setting value to a field. Use `:=` only for ref values created using `ref` function.
- Never use `%raw` to access object fields if you know the type.
- In tests, never log — use `Assert` module for all verifications.
- Use try/catch as expressions instead of refs for tracking success/failure.
