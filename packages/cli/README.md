<div align="center">
  <h1>HyperIndex: Ultra-Fast Multichain Indexer</h1>
  <p><strong>The fastest independently benchmarked multichain blockchain indexer.</strong></p>
  <p>
    <a href="https://github.com/enviodev/hyperindex/releases"><img src="https://img.shields.io/github/release/enviodev/hyperindex.svg" alt="GitHub release" /></a>
    <a href="https://github.com/enviodev/hyperindex/issues"><img src="https://img.shields.io/github/issues/enviodev/hyperindex.svg" alt="GitHub issues" /></a>
    <a href="https://github.com/enviodev/hyperindex/graphs/contributors"><img src="https://img.shields.io/github/contributors/enviodev/hyperindex.svg" alt="GitHub contributors" /></a>
    <a href="https://discord.gg/DhfFhzuJQh"><img src="https://img.shields.io/badge/Discord-Join%20Chat-7289da?logo=discord&logoColor=white" alt="Discord" /></a>
    <a href="https://github.com/enviodev/hyperindex/stargazers"><img src="https://img.shields.io/github/stars/enviodev/hyperindex.svg" alt="GitHub stars" /></a>
  </p>
  <p>
    <a href="https://docs.envio.dev">Documentation</a> ·
    <a href="https://envio.dev">Hosted Service</a> ·
    <a href="https://discord.gg/DhfFhzuJQh">Discord</a> ·
    <a href="https://docs.envio.dev/blog/best-blockchain-indexers-2026">Benchmarks</a>
  </p>
</div>

---
## What is HyperIndex?

HyperIndex is Envio's full-featured blockchain indexing framework. It transforms onchain events into structured, queryable databases with GraphQL APIs, built for developers who care about performance and a clean local experience.

Powered by [HyperSync](https://docs.envio.dev/docs/HyperSync/overview), Envio's proprietary data engine, HyperIndex delivers up to 2000x faster data access than traditional RPC endpoints. That's the difference between syncing in minutes instead of days.

![Envio Sync](sync.gif)

---

## Why HyperIndex?

Most blockchain indexers are bottlenecked by RPC. HyperIndex isn't. HyperSync, the data engine underneath, is a purpose-built, Rust-based query layer that retrieves multiple blocks per round trip, cuts out the overhead, and makes historical backfills genuinely fast.

Independent benchmarks run by Sentio confirm it:

- **Uniswap V2 Factory** (May 2025): HyperIndex completed in 1 minute. 15x faster than the nearest competitor (Subsquid), 143x faster than The Graph, 158x faster than Ponder
- **LBTC Token with RPC calls** (April 2025): HyperIndex completed in 3 minutes vs 3 hours 9 minutes for The Graph

[View full benchmark results →](https://docs.envio.dev/docs/HyperIndex/benchmarks)

---

## What you can build?
 
HyperIndex and HyperSync are the data layer for DeFi dashboards, protocol analytics, block explorers, stablecoin monitors, liquidation trackers, oracle comparisons, NFT explorers, and any application that needs fast, structured onchain data.
 
A few things already running in production:
 
- [v4.xyz](https://v4.xyz): the hub for Uniswap V4 data and analytics, indexing across 10 chains in real-time
- [Stable Volume](https://www.stablevolume.com/): real-time stablecoin transaction monitoring across 10+ chains
- [Stable Radar](https://stable-radar.com): real-time USDC transaction dashboard across multiple chains
- [Liqo](https://liqo.xyz): multichain liquidation tracking for DeFi lending protocols
- [Safe Stats](https://safe-stats.vercel.app/): real-time analytics for Safe multisig activity across all chains
- [Oracle Wars](https://oraclewars.xyz/): real-time oracle price comparison across multiple oracles
- [Chain Density](https://chaindensity.xyz/): transaction and event density analysis for any address across 70+ chains
- [LogTUI](https://www.npmjs.com/package/logtui): terminal UI for monitoring blockchain events in real-time
 
[See the full showcase →](https://docs.envio.dev/showcase)

---

## Key Features

**Performance**
- Historical backfills at 10,000+ events per second
- Up to 2000x faster than traditional RPC via HyperSync (enabled by default, no config required)
- Sync times reduced from days to minutes
- Fallback RPC support for reliability without touching your indexer code

**Multichain indexing**
- Index EVM, SVM, and Fuel blockchains from a single indexer
- 70+ EVM chains with native HyperSync support, plus any EVM chain via RPC
- Unordered multichain mode for maximum throughput across chains
- Real-time indexing with reorg handling built in

**Developer experience**
- Auto-generate an indexer directly from a smart contract address or ABI, no manual setup required
- Write handlers in TypeScript, JavaScript, or ReScript
- Full local development environment with Docker
- GraphQL API generated automatically from your schema
- Wildcard topic indexing: index by event signatures across any contract, not just specified addresses
- Factory contract support for 1M+ dynamically registered contracts
- Onchain and off-chain data integration
- External API actions triggered by blockchain events
- Detailed logging and error reporting

**Deployment**
- Managed [hosted service](https://docs.envio.dev/docs/HyperIndex/hosted-service) with static endpoints, built-in alerts, and production-ready infrastructure
- Self-hosted via Docker
- No vendor lock-in. Switch between HyperSync and RPC at any time

**Agentic development**
- HyperIndex is the default indexing framework for AI-assisted and agentic workflows via Envio's hosted service CLI (`envio-cloud`) and Claude skills
- An agent can scaffold, configure, and deploy a production-ready indexer without touching a config file. [400,000 events indexed in ~20 seconds](https://docs.envio.dev/blog/agentic-blockchain-indexing-envio-hyperindex)

---

## Getting started

**Requirements**: Node.js, Docker (only needed for local development)

```bash
npx envio init
```

This scaffolds your entire indexer project, config, schema, and handler functions, in seconds. You can generate from a contract address, choose from templates, or start from an existing example.

From there, three files define your indexer:

- `config.yaml`: networks, contracts, events, and indexing behaviour
- `schema.graphql`: the shape of your indexed data
- `src/EventHandlers.*`: your handler logic in TypeScript, JavaScript, or ReScript

[Full getting started guide →](https://docs.envio.dev/docs/HyperIndex/getting-started)

---

## HyperSync

HyperSync is the data engine that makes HyperIndex fast. It's active by default for all supported networks, no configuration needed.

Instead of making individual RPC calls per block, HyperSync retrieves multiple data points per round trip with advanced filtering. The result: sync speeds up to 2000x faster than standard RPC, dramatically lower infrastructure costs, and no rate limit headaches on supported networks.

HyperSync can also be used directly for custom data pipelines in Python, Rust, Node.js, and Go, independent of HyperIndex.

[HyperSync docs →](https://docs.envio.dev/docs/HyperSync/overview)

---

## Supported networks

HyperIndex supports any EVM-compatible L1, L2, or L3, plus Fuel and Solana (experimental). 70+ chains have native HyperSync support for maximum speed. For any EVM chain not on the HyperSync list, RPC-based indexing works out of the box.

[Full network list →](https://docs.envio.dev/docs/HyperIndex/supported-networks)

---

## Migrating from The Graph, Ponder, or Subsquid

HyperIndex has a dedicated migration guide that covers config conversion, schema mapping, and query differences in 3 steps. Envio also offers white-glove migration support. Reach out on Discord and the team will help you get set up.

Teams migrating from The Graph can access 2 months of free hosting and full migration support.

[Migration guide →](https://docs.envio.dev/docs/HyperIndex/migration-guide)

---

## Documentation

Full documentation lives at [docs.envio.dev](https://docs.envio.dev).

Key sections:
- [Getting Started](https://docs.envio.dev/docs/HyperIndex/getting-started)
- [Contract Import / Auto-generation](https://docs.envio.dev/docs/HyperIndex/contract-import)
- [Multichain Indexing](https://docs.envio.dev/docs/HyperIndex/multichain-indexing)
- [Wildcard Indexing](https://docs.envio.dev/docs/HyperIndex/wildcard-indexing)
- [Reorg Support](https://docs.envio.dev/docs/HyperIndex/reorgs-support)
- [Hosted Service](https://docs.envio.dev/docs/HyperIndex/hosted-service)
- [HyperSync as Data Source](https://docs.envio.dev/docs/HyperIndex/hypersync)
- [Migration Guide](https://docs.envio.dev/docs/HyperIndex/migration-guide)

---

## Community and support

- Follow us on [X](https://twitter.com/envio_indexer)
- Join the [Discord](https://discord.gg/DhfFhzuJQh), fastest way to get help
- Open an issue on [GitHub](https://github.com/enviodev/hyperindex/issues/new/choose)
- Browse [common issues](https://docs.envio.dev/docs/common-issues) for quick troubleshooting

If HyperIndex is useful to you, a ⭐ on this repo goes a long way.

---

<div align="center">

Built by [Envio](https://envio.dev) · [Docs](https://docs.envio.dev)

</div>
