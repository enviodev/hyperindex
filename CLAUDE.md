# HyperIndex

The contributor guide, for people and agents. A rule that a tool checks is not written here: the compiler, `pnpm lint`, clippy, the formatter and the push check each say what they want and how to fix it.

## Direction

- The runtime is moving from ReScript (`packages/envio/src`) to Rust (`packages/cli/src`). New runtime logic goes in Rust. ReScript changes are bindings, wiring and deletion.
- The napi boundary (`#[napi]` exports and `Core.addon`) is internal, not a published API. Change both sides for the better shape.
- No in-place migrations: on a schema or config change the user resyncs from scratch. The one exception is a chain added to config.yaml, which `envio start --chain <id>` adds to an existing schema when it names only that chain (`ResumePlan`). `packages/envio-tests/test/Migration_test.res` states what a restart does with each kind of config change.

## Where things are

- Rust CLI: `packages/cli`, entry `src/lib.rs`, commands `src/commands.rs`.
- Config pipeline: `human_config.rs` → `system_config.rs` → internal JSON → `hbs_templating/codegen_templates.rs` → `Config.res`.
- Runtime: `packages/envio`. Its tests: `packages/envio-tests`.
- Scenario projects: `scenarios/`.
- Edit `packages/cli/templates/` or `packages/envio/`, never the output under `<project>/.envio/`.
- Read `.res` modules; ignore compiled `.js`.

## Commands

- `pnpm`, not `npm` or `npx`. A fresh checkout needs `pnpm install` once.
- A Rust change needs no manual build: the tests and the `envio` bin run `cargo build --lib` themselves before they load the addon, unless a prebuilt `envio-<platform>` package is installed, as it is in CI.
- One test: `cd packages/envio-tests && pnpm rescript && pnpm vitest run -t "name"`. CI runs the full suite; locally run only what the change touches.

## A change

- Ships with a test that fails without it, driven from outside: real `config.yaml`, `schema.graphql` and handler source. If it can't be reached from outside, say so before fixing.
- Link the issue above the case: `// https://github.com/enviodev/hyperindex/issues/N`.
- Name every new metric, env var, exported type, log line and config key in the PR body.
- Names say what the thing does, spelled out: `entityIdToKey`, not `idKey`.
- A test checks the whole value with one assert.
- A comment is for what the code cannot show: a constraint, an invariant, a quirk of something we don't own.

## Skills

- `testing`: the three test rungs, virtual time, captured logs.
- `config-option`: adding or changing a `config.yaml` option end to end.
- `planted-bugs`: proving a test suite catches what it claims.

## Plan mode

- Make the plan extremely concise. Sacrifice grammar for the sake of concision.
- End each plan with unresolved questions, if any.
- Finish every plan by running tests.
