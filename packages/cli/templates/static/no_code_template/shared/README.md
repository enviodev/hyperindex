## Envio No-code Template

An ERC-20 indexer with no handlers and no `schema.graphql`. The `tables:` block
in `config.yaml` says which events to read and what to write, and the indexer
materializes the rows from that — column types included, inferred from the ABI.

`accounts` holds a balance per address, summed from both sides of every
transfer. `approvals` holds one row per owner/spender pair, each referencing the
accounts it names.

_Please refer to the [documentation website](https://docs.envio.dev) for a thorough guide on all [Envio](https://envio.dev) indexer features_

### Run

```bash
pnpm dev
```

Visit http://localhost:8080 to see the GraphQL Playground, local password is `testing`.

### Generate files from `config.yaml`

```bash
pnpm codegen
```

### Pre-requisites

- [Node.js v22+ (v24 recommended)](https://nodejs.org/en/download/current)
- [pnpm (use v8 or newer)](https://pnpm.io/installation)
- [Docker](https://www.docker.com/products/docker-desktop/) or [Podman](https://podman.io/)
