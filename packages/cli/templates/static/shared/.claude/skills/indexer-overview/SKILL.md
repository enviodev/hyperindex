---
name: indexer-overview
description: >-
  Use as the starting point for any indexer task. Prerequisites, commands,
  development workflow, project structure, and example repos. Start here
  when unfamiliar with the project or unsure which skill to use.
metadata:
  managed-by: envio
---

# Envio HyperIndex Indexer

Blockchain event indexer built with [Envio HyperIndex](https://docs.envio.dev). Processes on-chain events into a queryable GraphQL API backed by PostgreSQL.

## Prerequisites

- Node.js v22+ (v24 recommended), pnpm, Docker
- `ENVIO_API_TOKEN` env var (required for HyperSync data source)

## Commands

```bash
pnpm codegen          # Regenerate types from schema.graphql + config.yaml
pnpm tsc --noEmit     # Type-check without emitting
pnpm dev              # Run indexer locally
pnpm test             # Run tests (Vitest)
```

Use `pnpm`, not `npm`.

## Development Workflow

1. Edit `schema.graphql` and/or `config.yaml`
2. `pnpm codegen` — required after any schema/config change
3. Edit handlers in `src/`
4. `pnpm tsc --noEmit` — type-check
5. `pnpm test` — run tests (see `indexer-testing`)
6. `pnpm dev` — verify at runtime

## Project Structure

```
config.yaml          # Chain/contract configuration (see indexer-configuration)
schema.graphql       # Entity definitions (see indexer-schema)
src/                 # Handler source files (see indexer-handlers)
test/                # Tests (see indexer-testing)
```

## Example Repos

- [Uniswap v4 Indexer](https://github.com/enviodev/uniswap-v4-indexer)
- [Safe Analysis Indexer](https://github.com/enviodev/safe-analysis-indexer)

## Deep Documentation

Full reference: https://docs.envio.dev/docs/HyperIndex-LLM/hyperindex-complete
