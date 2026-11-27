---
name: config-option
description: >-
  Use when adding or changing a `config.yaml` option: the files the option
  passes through from YAML to the runtime, in order, and the generated docs to
  refresh.
---

# A `config.yaml` option, end to end

The pipeline, in the order to edit it. All Rust paths are under `packages/cli/src`.

1. **Failing test first.** A User API test in `packages/envio-tests` that sets the option in `~configYaml` and asserts what the indexer then does (see the `testing` skill).
2. **`config_parsing/human_config.rs`**: the user-facing structs, one module per ecosystem (`evm`, `fuel`, `svm`). Add the field with its doc comment and `#[schemars(description = ...)]`: that text is the JSON schema and the editor hover. Use `#[serde(skip_serializing_if = "Option::is_none")]` for an optional field. `cli_args/init_config.rs` builds these structs by hand, so the compiler sends you there next.
3. **`config_parsing/system_config.rs`**: the validated internal form. Carry the field over and reject bad values with an error that names the YAML key. Cross-field checks go in `config_parsing/validation.rs`.
4. **`config_parsing/public_config.rs`**: the internal JSON the runtime reads. Add the field in camelCase. Omit it when it holds the default (`skip_serializing_if`), so configs that don't use the option keep a byte-identical JSON.
5. **`packages/envio/src/Config.res`**: add the field to the matching `S.schema` and to the record it parses into. New runtime logic that acts on the option goes in Rust; the ReScript side only reads and passes it.
6. **`packages/envio/index.d.ts`**: when the option shows on the config a user reads (`EvmChainConfig` and its Fuel and SVM twins). Nothing fails if this is missed.
7. **`hbs_templating/codegen_templates.rs`**: only when the option changes the types a user sees (`<project>/.envio/types.d.ts`, `src/Indexer.res`). Its tests are snapshots: `INSTA_UPDATE=always cargo test --lib hbs_templating`, then read the `.snap` diff.

## Worked example: `start_block` on a contract address

- `human_config.rs`: `start_block: Option<u64>` on the chain's contract struct.
- `system_config.rs`: `ChainContract.start_block`, carried over as it is.
- `public_config.rs`: `ChainContractConfig.start_block`, emitted as `startBlock` and left out when unset.
- `Config.res`: `"startBlock": s.matches(S.option(S.int))` in `chainContractSchema`. The runtime falls back to the chain's start block.

## Commands

```bash
cd packages/cli
cargo test --lib config_parsing       # parsing tests; fixtures in test/configs
make update-schemas                   # packages/envio/{evm,fuel,svm}.schema.json
make update-help                      # CommandLineHelp.md, after a CLI flag change
make update-generated-docs            # both of the above
```

```bash
cd scenarios/test_codegen && pnpm exec envio codegen && pnpm test   # generated code still type-checks
pnpm exec rescript format src/Indexer.res                           # codegen rewrites this tracked file unformatted
```

- Commit the regenerated files with the change: `cargo test` compares each with what the code prints, so a stale one fails CI.
- A changed option means users resync from scratch. Don't write a migration; `packages/envio-tests/test/Migration_test.res` states what a restart does with each kind of config change, so add the new option there when a restart should refuse or accept it.
- An option a user can set belongs in the user skills too: `packages/cli/templates/static/shared/.claude/skills/indexer-configuration/SKILL.md`.
