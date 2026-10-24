## Envio ERC-8004 Template

This template indexes the [ERC-8004 Trustless Agents](https://eips.ethereum.org/EIPS/eip-8004) registries: agent registrations from the Identity Registry and client feedback from the Reputation Registry.

It shows two things that are specific to indexing this standard:

- `NewFeedback` carries `feedbackURI` and `feedbackHash` as non-indexed fields that `readFeedback()` does not return. The log is the only place the pointer to an agent's evidence exists, so an index is the only way to reach it.
- The Identity Registry is ERC-721 based, so an agent's ownership comes from the standard `Transfer` event while its registration URI comes from the custom `Registered` event. The handler merges both onto one `Agent` entity.

The registries are deployed as per-chain singletons. This template points at the Monad mainnet deployment; change the `chains` section in `config.yaml` to index another one.

_Please refer to the [documentation website](https://docs.envio.dev) for a thorough guide on all [Envio](https://envio.dev) indexer features_

### Run

```bash
pnpm dev
```

Visit http://localhost:8080 to see the GraphQL Playground, local password is `testing`.

### Generate files from `config.yaml` or `schema.graphql`

```bash
pnpm codegen
```

### Pre-requisites

- [Node.js v22+ (v24 recommended)](https://nodejs.org/en/download/current)
- [pnpm (use v8 or newer)](https://pnpm.io/installation)
- [Docker](https://www.docker.com/products/docker-desktop/) or [Podman](https://podman.io/)
