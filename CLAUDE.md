- Never delete comments describing unobvious logic when refactoring. Move or update them to match the new code, but preserve their intent.
- Use `pnpm` over `npm`/`npx`.
- Always use single assert to check the whole value instead of multiple asserts for every field.

## Plan Mode

- Make the plan extremely concise. Sacrifice grammar for the sake of concision.
- At the end of each plan, give me a list of unresolved questions to answer, if any.
- Finish every plan by running tests.

## Navigation

- Rust CLI: `packages/cli`, entry at `lib.rs`, commands at `commands.rs`.
- Config parsing pipeline: `human_config.rs` → `system_config.rs` → `hbs_templating/codegen_templates.rs`.
- Shared runtime library: `packages/envio`.
- To edit runtime code, edit templates under `packages/cli/templates/`, not files in `generated/`.
- Prefer reading `.res` modules directly; ignore compiled `.js` artifacts.

## Testing

Prefer Public module API for testing.

Verify that tests pass by running a compiler `pnpm rescript` and tests `pnpm vitest`. Use `_only` to specify which tests to run.

## ReScript

- When using `Utils.magic` for type casting, always add explicit type annotations: `value->(Utils.magic: inputType => outputType)`
- Always use ReScript 11 documentation. Never suggest ReasonML syntax.
- Never use `[| item |]` to create an array. Use `[ item ]` instead.
- Must always use `=` for setting value to a field. Use `:=` only for ref values created using `ref` function.
- Never use `%raw` to access object fields if you know the type.
- In tests, never log — use `Assert` module for all verifications.
- Use try/catch as expressions instead of refs for tracking success/failure.
