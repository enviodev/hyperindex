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
- Shared runtime library: `packages/envio`.
- To edit runtime code, edit templates under `packages/cli/templates/`, not files in `generated/`.
- Prefer reading `.res` modules directly; ignore compiled `.js` artifacts.

## Testing

Prefer Public module API for testing.

Verify that tests pass by running a compiler `pnpm rescript-legacy` and tests `pnpm vitest run`.

## ReScript

- When using `Utils.magic` for type casting, always add explicit type annotations: `value->(Utils.magic: inputType => outputType)`
- Always use ReScript 12 documentation. Never suggest ReasonML syntax.
- Never use `[| item |]` to create an array. Use `[ item ]` instead.
- Must always use `=` for setting value to a field. Use `:=` only for ref values created using `ref` function.
- Never use `%raw` to access object fields if you know the type.
- In tests, never log — use `Assert` module for all verifications.
- Use try/catch as expressions instead of refs for tracking success/failure.
