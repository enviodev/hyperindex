# test_codegen

A codegen compile fixture, not a test suite.

`config.yaml` and `schema.graphql` carry the shapes codegen is most likely to
break on: a field named after a ReScript keyword, entity names at Postgres'
63-character identifier limit, an event name longer than an enum value can
hold, an event param named after a keyword, indexed tuples nested two deep,
per-event field selections, overloaded and aliased event names, and a contract
shared across chains.

`pnpm test` runs `envio codegen` output through the ReScript and TypeScript
compilers. Nothing here asserts behaviour — that lives in
`packages/envio-tests`, and the text codegen emits for this surface is
snapshotted in `packages/cli/src/hbs_templating/codegen_templates.rs`
(`indexer_code_for_hostile_config`).
