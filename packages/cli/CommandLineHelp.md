# Command-Line Help for `envio`

This document contains the help content for the `envio` command-line program.

**Command Overview:**

* [`envio`↴](#envio)
* [`envio init`↴](#envio-init)
* [`envio init contract-import`↴](#envio-init-contract-import)
* [`envio init contract-import explorer`↴](#envio-init-contract-import-explorer)
* [`envio init contract-import local`↴](#envio-init-contract-import-local)
* [`envio init template`↴](#envio-init-template)
* [`envio init svm`↴](#envio-init-svm)
* [`envio init svm template`↴](#envio-init-svm-template)
* [`envio init fuel`↴](#envio-init-fuel)
* [`envio init fuel contract-import`↴](#envio-init-fuel-contract-import)
* [`envio init fuel contract-import local`↴](#envio-init-fuel-contract-import-local)
* [`envio init fuel template`↴](#envio-init-fuel-template)
* [`envio dev`↴](#envio-dev)
* [`envio stop`↴](#envio-stop)
* [`envio codegen`↴](#envio-codegen)
* [`envio local`↴](#envio-local)
* [`envio local docker`↴](#envio-local-docker)
* [`envio local docker up`↴](#envio-local-docker-up)
* [`envio local docker down`↴](#envio-local-docker-down)
* [`envio local db-migrate`↴](#envio-local-db-migrate)
* [`envio local db-migrate up`↴](#envio-local-db-migrate-up)
* [`envio local db-migrate down`↴](#envio-local-db-migrate-down)
* [`envio local db-migrate setup`↴](#envio-local-db-migrate-setup)
* [`envio start`↴](#envio-start)
* [`envio metrics`↴](#envio-metrics)
* [`envio data`↴](#envio-data)
* [`envio skills`↴](#envio-skills)
* [`envio skills update`↴](#envio-skills-update)
* [`envio tools`↴](#envio-tools)
* [`envio tools search-docs`↴](#envio-tools-search-docs)
* [`envio tools fetch-docs`↴](#envio-tools-fetch-docs)
* [`envio config`↴](#envio-config)
* [`envio config view`↴](#envio-config-view)

## `envio`

**Usage:** `envio [OPTIONS] <COMMAND>`

###### **Subcommands:**

* `init` — Initialize an indexer with one of the initialization options
* `dev` — Development commands for starting, stopping, and restarting the indexer. Runs codegen automatically before launching
* `stop` — Stop the local environment - delete the database and stop all processes (including Docker) for the current directory
* `codegen` — Generate indexing code from user-defined configuration & schema files
* `local` — Prepare local environment for envio testing
* `start` — Start the indexer. Runs codegen automatically before launching so the on-disk types stay in sync with `config.yaml` and `schema.graphql`
* `metrics` — Fetch raw Prometheus metrics from the running indexer's /metrics endpoint
* `data` — Query raw blockchain data — blocks, logs, transactions on EVM chains using the same `where` syntax as indexer filters
* `skills` — Manage Envio-provided Claude Code skills under `.claude/skills/`
* `tools` — Tools for people and AI agents (search-docs, fetch-docs). Run `envio tools help` for details
* `config` — Inspect the indexer config

###### **Options:**

* `-d`, `--directory <DIRECTORY>` — The directory of the project. Defaults to current dir ("./")
* `--config <CONFIG>` — The file in the project containing the configuration. It can also be set via the `ENVIO_CONFIG` environment variable

  Default value: `config.yaml`



## `envio init`

Initialize an indexer with one of the initialization options

**Usage:** `envio init [OPTIONS] [COMMAND]`

###### **Subcommands:**

* `contract-import` — Initialize Evm indexer by importing config from a contract for a given chain
* `template` — Initialize Evm indexer from an example template
* `svm` — Initialization option for creating Svm indexer
* `fuel` — Initialization option for creating Fuel indexer

###### **Options:**

* `-n`, `--name <NAME>` — The name of your project
* `-l`, `--language <LANGUAGE>` — The language used to write handlers

  Possible values: `typescript`, `rescript`

* `--package-manager <PACKAGE_MANAGER>` — The package manager used for `install` and post-init build steps (default: pnpm)

  Possible values: `pnpm`, `npm`, `yarn`, `bun`

* `--api-token <API_TOKEN>` — The hypersync API key to be initialized in your templates .env file. Falls back to the `ENVIO_API_TOKEN` environment variable



## `envio init contract-import`

Initialize Evm indexer by importing config from a contract for a given chain

**Usage:** `envio init contract-import [OPTIONS] [COMMAND]`

###### **Subcommands:**

* `explorer` — Initialize by pulling the contract ABI from a block explorer
* `local` — Initialize from a local json ABI file

###### **Options:**

* `-c`, `--contract-address <CONTRACT_ADDRESS>` — Contract address to generate the config from
* `--single-contract` — If selected, prompt will not ask for additional contracts/addresses/chains
* `--all-events` — If selected, prompt will not ask to confirm selection of events on a contract



## `envio init contract-import explorer`

Initialize by pulling the contract ABI from a block explorer

**Usage:** `envio init contract-import explorer [OPTIONS]`

###### **Options:**

* `-b`, `--blockchain <BLOCKCHAIN>` — Network to import the contract from

  Possible values: `abstract`, `amoy`, `arbitrum-nova`, `arbitrum-one`, `arbitrum-sepolia`, `arbitrum-testnet`, `aurora`, `aurora-testnet`, `avalanche`, `b2-testnet`, `base`, `base-sepolia`, `berachain`, `blast`, `blast-sepolia`, `boba`, `bsc`, `bsc-testnet`, `celo`, `celo-alfajores`, `celo-baklava`, `citrea-testnet`, `crab`, `curtis`, `ethereum-mainnet`, `evmos`, `fantom`, `fantom-testnet`, `fhenix-helium`, `flare`, `fraxtal`, `fuji`, `galadriel-devnet`, `gnosis`, `gnosis-chiado`, `goerli`, `harmony`, `holesky`, `hoodi`, `hyperliquid`, `kroma`, `linea`, `linea-sepolia`, `lisk`, `lukso`, `lukso-testnet`, `manta`, `mantle`, `mantle-testnet`, `megaeth-testnet`, `megaeth-testnet2`, `metis`, `mode`, `mode-sepolia`, `monad`, `monad-testnet`, `moonbase-alpha`, `moonbeam`, `moonriver`, `morph`, `morph-testnet`, `neon-evm`, `opbnb`, `optimism`, `optimism-sepolia`, `plasma`, `poa-core`, `poa-sokol`, `polygon`, `polygon-zkevm`, `polygon-zkevm-testnet`, `rsk`, `saakuru`, `scroll`, `scroll-sepolia`, `sei`, `sei-testnet`, `sepolia`, `shimmer-evm`, `sonic`, `sonic-testnet`, `sophon`, `sophon-testnet`, `swell`, `taiko`, `tangle`, `unichain`, `unichain-sepolia`, `worldchain`, `xdc`, `xdc-testnet`, `zeta`, `zksync-era`, `zora`, `zora-sepolia`

* `--api-token <API_TOKEN>` — API token for the block explorer
* `--single-contract` — If selected, prompt will not ask for additional contracts/addresses/chains
* `--all-events` — If selected, prompt will not ask to confirm selection of events on a contract



## `envio init contract-import local`

Initialize from a local json ABI file

**Usage:** `envio init contract-import local [OPTIONS]`

###### **Options:**

* `-a`, `--abi-file <ABI_FILE>` — The path to a json abi file
* `--contract-name <CONTRACT_NAME>` — The name of the contract
* `-b`, `--blockchain <BLOCKCHAIN>` — Name or ID of the contract network
* `-r`, `--rpc-url <RPC_URL>` — The rpc url to use if the network id used is unsupported by our hypersync
* `-s`, `--start-block <START_BLOCK>` — The start block to use on this network
* `--single-contract` — If selected, prompt will not ask for additional contracts/addresses/chains
* `--all-events` — If selected, prompt will not ask to confirm selection of events on a contract



## `envio init template`

Initialize Evm indexer from an example template

**Usage:** `envio init template [OPTIONS]`

###### **Options:**

* `-t`, `--template <TEMPLATE>` — Name of the template to be used in initialization

  Possible values: `greeter`, `erc20`, `feature-external-calls`, `feature-factory`




## `envio init svm`

Initialization option for creating Svm indexer

**Usage:** `envio init svm [COMMAND]`

###### **Subcommands:**

* `template` — Initialize Svm indexer from an example template



## `envio init svm template`

Initialize Svm indexer from an example template

**Usage:** `envio init svm template [OPTIONS]`

###### **Options:**

* `-t`, `--template <TEMPLATE>` — Name of the template to be used in initialization

  Possible values: `feature-block-handler`




## `envio init fuel`

Initialization option for creating Fuel indexer

**Usage:** `envio init fuel [COMMAND]`

###### **Subcommands:**

* `contract-import` — Initialize Fuel indexer by importing config from a contract for a given chain
* `template` — Initialize Fuel indexer from an example template



## `envio init fuel contract-import`

Initialize Fuel indexer by importing config from a contract for a given chain

**Usage:** `envio init fuel contract-import [OPTIONS] [COMMAND]`

###### **Subcommands:**

* `local` — Initialize from a local json ABI file

###### **Options:**

* `-c`, `--contract-address <CONTRACT_ADDRESS>` — Contract address to generate the config from
* `--single-contract` — If selected, prompt will not ask for additional contracts/addresses/chains
* `--all-events` — If selected, prompt will not ask to confirm selection of events on a contract



## `envio init fuel contract-import local`

Initialize from a local json ABI file

**Usage:** `envio init fuel contract-import local [OPTIONS]`

###### **Options:**

* `-a`, `--abi-file <ABI_FILE>` — The path to a json abi file
* `--contract-name <CONTRACT_NAME>` — The name of the contract
* `-b`, `--blockchain <BLOCKCHAIN>` — Which Fuel network to use

  Possible values: `mainnet`, `testnet`

* `--single-contract` — If selected, prompt will not ask for additional contracts/addresses/chains
* `--all-events` — If selected, prompt will not ask to confirm selection of events on a contract



## `envio init fuel template`

Initialize Fuel indexer from an example template

**Usage:** `envio init fuel template [OPTIONS]`

###### **Options:**

* `-t`, `--template <TEMPLATE>` — Name of the template to be used in initialization

  Possible values: `greeter`




## `envio dev`

Development commands for starting, stopping, and restarting the indexer. Runs codegen automatically before launching

**Usage:** `envio dev [OPTIONS]`

###### **Options:**

* `-r`, `--restart` — Force restart: clear the database and re-index from scratch. Required when config/schema/ABI changes are incompatible with the existing indexer state



## `envio stop`

Stop the local environment - delete the database and stop all processes (including Docker) for the current directory

**Usage:** `envio stop`



## `envio codegen`

Generate indexing code from user-defined configuration & schema files

**Usage:** `envio codegen`



## `envio local`

Prepare local environment for envio testing

**Usage:** `envio local <COMMAND>`

###### **Subcommands:**

* `docker` — Local Envio environment commands
* `db-migrate` — Local Envio database commands



## `envio local docker`

Local Envio environment commands

**Usage:** `envio local docker <COMMAND>`

###### **Subcommands:**

* `up` — Start Docker containers (Postgres + Hasura) for local environment
* `down` — Stop and remove Docker containers for local environment



## `envio local docker up`

Start Docker containers (Postgres + Hasura) for local environment

**Usage:** `envio local docker up`



## `envio local docker down`

Stop and remove Docker containers for local environment

**Usage:** `envio local docker down`



## `envio local db-migrate`

Local Envio database commands

**Usage:** `envio local db-migrate <COMMAND>`

###### **Subcommands:**

* `up` — Migrate latest schema to database
* `down` — Drop database schema
* `setup` — Setup database by dropping schema and then running migrations



## `envio local db-migrate up`

Migrate latest schema to database

**Usage:** `envio local db-migrate up`



## `envio local db-migrate down`

Drop database schema

**Usage:** `envio local db-migrate down`



## `envio local db-migrate setup`

Setup database by dropping schema and then running migrations

**Usage:** `envio local db-migrate setup`



## `envio start`

Start the indexer. Runs codegen automatically before launching so the on-disk types stay in sync with `config.yaml` and `schema.graphql`

**Usage:** `envio start [OPTIONS]`

###### **Options:**

* `-r`, `--restart` — Clear your database and restart indexing from scratch



## `envio metrics`

Fetch raw Prometheus metrics from the running indexer's /metrics endpoint

**Usage:** `envio metrics`



## `envio data`

Query raw blockchain data — blocks, logs, transactions on EVM chains using the same `where` syntax as indexer filters.

Output is TOON (token-oriented) tabular form.

Example — earliest USDC transfers on Base: `envio data block.number log.srcAddress --chain=base --where='{ block: { number: { _gte: 0 } }, log: { srcAddress: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" } }'`

Example — current archive height: `envio data knownHeight --chain=arbitrum-one`

**Usage:** `envio data [OPTIONS] --chain <CHAIN> [FIELD]...`

###### **Arguments:**

* `<FIELD>` — Fields to fetch (e.g. `block.number`, `log.srcAddress`, `transaction.transactionIndex`). Use `knownHeight` to get the chain's current archive height

###### **Options:**

* `--chain <CHAIN>` — Chain id (e.g. `8453`) or kebab-case name (e.g. `base`, `arbitrum-one`). Solana is not supported yet
* `--where <WHERE_FILTER>` — Filter rows (JSON5: unquoted keys, single quotes, trailing commas, `//` comments). Group fields under `block`, `transaction`, `log`. Match any field with a value, array, or `_eq`/`_in`; numeric fields also take `_gt`/`_gte`/`_lt`/`_lte`. Example: --where='{ block: { number: { _gte: 1000, _lte: 2000 } }, log: { srcAddress: "0xa0b8..." } }'



## `envio skills`

Manage Envio-provided Claude Code skills under `.claude/skills/`

**Usage:** `envio skills <COMMAND>`

###### **Subcommands:**

* `update` — Re-extract every skill shipped by this CLI version, overwriting the matching directories under `<cwd>/.claude/skills/`. Skills not shipped by envio are left untouched



## `envio skills update`

Re-extract every skill shipped by this CLI version, overwriting the matching directories under `<cwd>/.claude/skills/`. Skills not shipped by envio are left untouched

**Usage:** `envio skills update`



## `envio tools`

Tools for people and AI agents (search-docs, fetch-docs). Run `envio tools help` for details

**Usage:** `envio tools <COMMAND>`

###### **Subcommands:**

* `search-docs` — Full-text search over Envio docs; prints matching titles, URLs, and snippets. Pair with `fetch-docs` to read a hit in full
* `fetch-docs` — Print the full markdown of a docs page by URL. Use a URL returned by `search-docs`



## `envio tools search-docs`

Full-text search over Envio docs; prints matching titles, URLs, and snippets. Pair with `fetch-docs` to read a hit in full

**Usage:** `envio tools search-docs <QUERY>`

###### **Arguments:**

* `<QUERY>` — The search query



## `envio tools fetch-docs`

Print the full markdown of a docs page by URL. Use a URL returned by `search-docs`

**Usage:** `envio tools fetch-docs <URL>`

###### **Arguments:**

* `<URL>` — The full URL of the documentation page to fetch



## `envio config`

Inspect the indexer config

**Usage:** `envio config <COMMAND>`

###### **Subcommands:**

* `view` — Print the resolved indexer config as JSON



## `envio config view`

Print the resolved indexer config as JSON

**Usage:** `envio config view`




