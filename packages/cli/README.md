<div align="center">
  <h1>HyperIndex</h1>
  <p><strong>Build custom blockchain APIs and analytics. Real-time, with enterprise SLAs.</strong></p>
  <p>
    <a href="https://github.com/enviodev/hyperindex/releases"><img src="https://img.shields.io/github/release/enviodev/hyperindex.svg" alt="GitHub release" /></a>
    <a href="https://github.com/enviodev/hyperindex/issues"><img src="https://img.shields.io/github/issues/enviodev/hyperindex.svg" alt="GitHub issues" /></a>
    <a href="https://github.com/enviodev/hyperindex/graphs/contributors"><img src="https://img.shields.io/github/contributors/enviodev/hyperindex.svg" alt="GitHub contributors" /></a>
    <a href="https://discord.gg/DhfFhzuJQh"><img src="https://img.shields.io/badge/Discord-Join%20Chat-7289da?logo=discord&logoColor=white" alt="Discord" /></a>
    <a href="https://github.com/enviodev/hyperindex/stargazers"><img src="https://img.shields.io/github/stars/enviodev/hyperindex.svg" alt="GitHub stars" /></a>
  </p>
  <p>
    <a href="https://docs.envio.dev">Documentation</a> ·
    <a href="https://envio.dev">Envio Cloud</a> ·
    <a href="https://github.com/enviodev/open-indexer-benchmark">Benchmark</a> ·
    <a href="https://docs.envio.dev/docs/HyperIndex/quickstart-with-ai">Build with AI</a> ·
    <a href="https://discord.gg/DhfFhzuJQh">Discord</a> ·
    <a href="https://envio.dev/pricing">Contact sales</a>
  </p>
</div>

---
## What is HyperIndex?

HyperIndex is Envio's blockchain indexing framework. Choose the contracts and events to track, write TypeScript handlers that shape the data, and HyperIndex keeps it up to date across EVM chains, Solana and Fuel, handles chain reorganisations, and serves the result as a GraphQL API.

It reads chain data through [HyperSync](https://docs.envio.dev/docs/HyperSync/overview), Envio's blockchain data API, which is up to 2,000x faster than JSON-RPC. Run it yourself with Docker, or deploy to [Envio Cloud](https://docs.envio.dev/docs/HyperIndex/hosted-service), from a free development plan up to Dedicated deployments with an SLA of up to 99.99% uptime.

![Envio Sync](sync.gif)

---

## Why HyperIndex?

Most blockchain indexers are bottlenecked by RPC. HyperIndex isn't. HyperSync, the data engine underneath, is a purpose-built, Rust-based query layer that retrieves multiple blocks per round trip, cuts out the overhead, and makes historical backfills genuinely fast.

In the [open indexer benchmark](https://github.com/enviodev/open-indexer-benchmark), HyperIndex is 6–879x faster across the speed scenarios, and passes every reliability check. Every number there comes from code in the repository, so you can run it yourself.

[How the benchmarks work →](https://docs.envio.dev/docs/HyperIndex/benchmarks)

---

## What you can build?
 
HyperIndex and HyperSync are the data layer for DeFi dashboards, protocol analytics, block explorers, stablecoin monitors, liquidation trackers, oracle comparisons, NFT explorers, and any application that needs fast, structured onchain data.
 
A few apps built with them, from the showcase:
 
- [v4.xyz](https://v4.xyz): the hub for Uniswap V4 data and analytics, indexed in real time across chains
- [Stable Volume](https://www.stablevolume.com/): real-time stablecoin transaction monitoring across chains
- [Stable Radar](https://stable-radar.com): real-time USDC transaction dashboard across multiple chains
- [Liqo](https://liqo.xyz): multichain liquidation tracking for DeFi lending protocols
- [Oracle Wars](https://oraclewars.xyz/): real-time oracle price comparison across multiple oracles
- [Chain Density](https://chaindensity.xyz/): transaction and event density analysis for any address across chains
- [LogTUI](https://www.npmjs.com/package/logtui): terminal UI for monitoring blockchain events in real-time
 
[See the full showcase →](https://docs.envio.dev/showcase)

---

## Key Features

**Performance**
- Historical backfills at 100,000+ events per second ([benchmarking](https://docs.envio.dev/docs/HyperIndex/benchmarking))
- Up to 2,000x faster than JSON-RPC via HyperSync (on by default, no config required)
- Fallback RPC support for reliability without touching your indexer code

**Multichain indexing**
- Index EVM, SVM, and Fuel blockchains from a single indexer
- Every chain on the [HyperSync network list](https://docs.envio.dev/docs/HyperSync/hypersync-supported-networks), plus any EVM chain via RPC
- Real-time indexing with reorg handling built in

**Developer experience**
- Auto-generate an indexer directly from a smart contract address or ABI, no manual setup required
- Write handlers in TypeScript or ReScript, and plain JavaScript handler files load too
- Full local development environment with Docker
- GraphQL API generated automatically from your schema
- Wildcard topic indexing: index by event signatures across any contract, not just specified addresses
- Factory contract support for dynamically registered contracts
- Onchain and off-chain data integration
- External API actions triggered by blockchain events
- Detailed logging and error reporting

**Deployment**
- [Envio Cloud](https://docs.envio.dev/docs/HyperIndex/hosted-service), managed hosting with static endpoints and built-in alerts, from a free development plan up to Dedicated deployments with an SLA of up to 99.99% uptime
- Self-hosted via Docker
- No vendor lock-in. Switch between HyperSync and RPC at any time

**Agentic development**
- Build and deploy with an AI agent using the Envio Cloud CLI (`envio-cloud`) and the [HyperIndex skills](https://github.com/enviodev/hyperindex/tree/main/packages/cli/templates/static/shared/.claude/skills) that `envio init` adds to every project
- An agent can scaffold, configure, and deploy a production-ready indexer without touching a config file. [400,000 events indexed in ~20 seconds](https://docs.envio.dev/blog/agentic-blockchain-indexing-envio-hyperindex)
- Powerful built-in testing framework purpose-built for AI-driven development. Agents can write, run, and iterate on handler tests in a tight feedback loop, catching regressions before deploy

---

## Getting started

**Requirements**: Node.js 22.15 or newer, and Docker for local development. pnpm is recommended.

```bash
pnpx envio init
```

This scaffolds your entire indexer project, config, schema, and handler functions, in seconds. You can generate from a contract address, choose from templates, or start from an existing example.

From there, three files define your indexer:

- `config.yaml`: networks, contracts, events, and indexing behaviour
- `schema.graphql`: the shape of your indexed data
- `src/handlers`: your handler logic in TypeScript or ReScript

[Full getting started guide →](https://docs.envio.dev/docs/HyperIndex/getting-started)

---

## HyperSync

HyperSync is the data engine that makes HyperIndex fast. It's active by default for all supported networks, no configuration needed.

Instead of making individual RPC calls per block, HyperSync retrieves multiple data points per round trip with advanced filtering. The result is sync speeds up to 2,000x faster than JSON-RPC, lower infrastructure costs, and no rate limits to work around on supported networks.

HyperSync can also be used directly for custom data pipelines in Python, Rust, Node.js, and Go, independent of HyperIndex.

[HyperSync docs →](https://docs.envio.dev/docs/HyperSync/overview)

---

## Supported networks

HyperIndex supports any EVM-compatible L1, L2, or L3, plus Fuel and Solana. Chains on the [HyperSync network list](https://docs.envio.dev/docs/HyperSync/hypersync-supported-networks) get first-class HyperSync support. For any EVM chain not on the HyperSync list, RPC-based indexing works out of the box. Solana indexing runs on HyperSync for Solana, with instruction-level handlers and IDL-aware decoding.

[Full network list →](https://docs.envio.dev/docs/HyperIndex/supported-networks)

---

## Migrating an existing indexer

The migration guides cover config conversion, schema mapping and query differences, and you can [migrate with an AI agent](https://docs.envio.dev/docs/HyperIndex/migrate-with-ai). If you run subgraphs, Envio can also migrate and host them for you with Subgraph Hosting, while your applications keep querying a subgraph-compatible endpoint. For hands-on help, see [services](https://envio.dev/pricing/services) or ask on Discord.

[Migration guides →](https://docs.envio.dev/docs/HyperIndex/migration-guide)

---

## Documentation

Full documentation lives at [docs.envio.dev](https://docs.envio.dev).

Key sections:
- [Getting Started](https://docs.envio.dev/docs/HyperIndex/getting-started)
- [Contract Import / Auto-generation](https://docs.envio.dev/docs/HyperIndex/contract-import)
- [Multichain Indexing](https://docs.envio.dev/docs/HyperIndex/multichain-indexing)
- [Wildcard Indexing](https://docs.envio.dev/docs/HyperIndex/wildcard-indexing)
- [Reorg Support](https://docs.envio.dev/docs/HyperIndex/reorgs-support)
- [Envio Cloud](https://docs.envio.dev/docs/HyperIndex/hosted-service)
- [HyperSync as Data Source](https://docs.envio.dev/docs/HyperIndex/hypersync)
- [Migration Guide](https://docs.envio.dev/docs/HyperIndex/migration-guide)

---

## Build with an AI agent

HyperIndex works with Claude Code, Cursor, Codex and other coding agents.

- **Docs for agents.** Point your agent at [llms.txt](https://docs.envio.dev/llms.txt), or the full text at [llms-full.txt](https://docs.envio.dev/llms-full.txt).
- **Docs MCP server.** Add `https://docs.envio.dev/mcp` to your agent for `docs_search` and `docs_fetch`. See the [MCP server guide](https://docs.envio.dev/docs/HyperIndex/mcp-server).
- **Skills.** `pnpx envio init` adds the [HyperIndex skills](https://github.com/enviodev/hyperindex/tree/main/packages/cli/templates/static/shared/.claude/skills) to every new project. After upgrading `envio`, run `pnpm envio skills update` to refresh them.
- **Quickstart.** Follow [Quickstart with AI](https://docs.envio.dev/docs/HyperIndex/quickstart-with-ai) to go from a contract address to a deployed GraphQL API.

---

## Community and support

- Follow us on [X](https://twitter.com/envio_indexer)
- Join the [Discord](https://discord.gg/DhfFhzuJQh) or [Telegram](https://t.me/+BeS5ihVUFONjNGFk), the fastest ways to get help
- Open an issue on [GitHub](https://github.com/enviodev/hyperindex/issues/new/choose)
- Browse [common issues](https://docs.envio.dev/docs/common-issues) for quick troubleshooting

If HyperIndex is useful to you, a ⭐ on this repo goes a long way.

---

<div align="center">

Built by [Envio](https://envio.dev) · [Docs](https://docs.envio.dev)

</div>
