# IDL provenance

Jupiter, Drift, and Kamino ship unmodified legacy Anchor IDLs. `config.yaml`
names the program and the `idl:` path. Register `indexer.onInstruction`
handlers for the instructions to handle, and select payload with `fields`.

All three are **legacy Anchor (pre-0.30)**: top-level `name` / `version` /
`instructions` / `accounts` / `types` / `events` / `errors`. No top-level
`address`, no `metadata.spec`, no per-instruction `discriminator` arrays.
Discriminators are `sha256("global:<snake_case_name>")[..8]`.

| Program | File | Format | Source |
|---|---|---|---|
| Jupiter v6 | `jupiter.json` | legacy Anchor | https://raw.githubusercontent.com/jup-ag/jupiter-cpi/main/idl.json |
| Drift v2 | `drift.json` | legacy Anchor | https://raw.githubusercontent.com/drift-labs/protocol-v2/master/sdk/src/idl/drift.json |
| Kamino Lend | `kamino.json` | legacy Anchor | https://raw.githubusercontent.com/Kamino-Finance/klend-sdk/master/src/idl/klend.json |

None of these IDLs embed the on-chain program id. `program_id` in
`config.yaml` comes from the spec, not the file.
