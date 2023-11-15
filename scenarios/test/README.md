# Envio Uniswap V3 example

> This is a development repo that is undergoing continual changes for benchmarking purposes.

This repo contains an example Envio indexer built using TypeScript for the [Uniswap V3 USDC / ETH
0.05% pool](https://etherscan.io/address/0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640) deployed on Ethereum Mainnet.

`Swap` events from the contract are indexed as entities and the `LiquidityPool` entity is updated on each `Swap` event to track cumulative statistics for the pool.

The indexer has been built using v0.0.21 of Envio.

## Steps to run the indexer

1. Clone the repo
1. Install any other pre-requisite packages for Envio listed [here](https://docs.envio.dev/docs/installation#prerequisites)
1. Install Envio via `npm i -g envio@v0.0.21`
1. Generate indexing code via `envio codegen`
1. Run the indexer via `envio dev` (make sure you have Docker running)
1. Stop the indexer via `envio start`

_Please refer to the [documentation website](https://docs.envio.dev) for a thorough guide on all Envio indexer features_
