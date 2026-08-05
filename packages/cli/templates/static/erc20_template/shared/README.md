## Envio ERC20 Template

_Please refer to the [documentation website](https://docs.envio.dev) for a thorough guide on all [Envio](https://envio.dev) indexer features_

The `accounts` and `approvals` tables are declared under `tables` in
`config.yaml`, which owns both their schema and their writes. Each column's type
is inferred from the events it reads, so this indexer has no `schema.graphql` and
no handlers. To write a table from handler code instead, declare its `fields`
rather than a `select`.

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
