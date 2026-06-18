---
name: indexer-troubleshooting
description: >-
  Use when the indexer fails to start, codegen errors, types are stale,
  Docker or database issues, RPC errors, or something is not working.
  Common error messages and fixes.
metadata:
  managed-by: envio
---

# Troubleshooting

## Stale Types / Codegen Issues

**Symptom:** Type errors after editing `schema.graphql` or `config.yaml`.

```bash
pnpm codegen
```

Always run codegen after any schema or config change.

## Docker / Database Not Running

**Symptom:** `pnpm dev` fails with connection refused or database errors.

```bash
docker info  # check Docker is running
```

The indexer needs Docker for PostgreSQL. Start Docker and retry.

## Environment Variables

All env vars MUST use the `ENVIO_` prefix. The hosted service only exposes variables with this prefix at runtime.

```yaml
# WRONG
rpc:
  - url: ${RPC_URL}

# CORRECT
rpc:
  - url: ${ENVIO_RPC_URL}
```

## RPC / HyperSync Errors

**"rate limited" or timeout errors:** See `indexer-performance` skill for RPC tuning parameters.

**Missing `ENVIO_API_TOKEN`:** Required for HyperSync. Get an Envio API token at https://envio.dev/app/api-tokens, then set it in `.env` or shell environment.

## Common Runtime Errors

**"field not indexed"** — `getWhere` only works on `id` and fields with `@index` in `schema.graphql`.

**"entity is read-only"** — Entities from `context.Entity.get()` are frozen. Spread to update: `context.Entity.set({ ...entity, field: newValue })`.

**"Cannot find module 'envio'"** — Run `pnpm install`.

**Codegen output stale after `config.yaml` change** — Run `pnpm codegen` again.
