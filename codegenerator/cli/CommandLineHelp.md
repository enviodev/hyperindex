# Command-Line Help for `envio`

This document contains the help content for the `envio` command-line program.

**Command Overview:**

* [`envio`↴](#envio)
* [`envio init`↴](#envio-init)
* [`envio init template`↴](#envio-init-template)
* [`envio init subgraph-migration`↴](#envio-init-subgraph-migration)
* [`envio init contract-import`↴](#envio-init-contract-import)
* [`envio init contract-import explorer`↴](#envio-init-contract-import-explorer)
* [`envio init contract-import local`↴](#envio-init-contract-import-local)
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

## `envio`

**Usage:** `envio [OPTIONS] <COMMAND>`

###### **Subcommands:**

* `init` — Initialize an indexer with one of the initialization options
* `dev` — Development commands for starting, stopping, and restarting the indexer with automatic codegen for any changed files
* `stop` — Stop the local environment - delete the database and stop all processes (including Docker) for the current directory
* `codegen` — Generate indexing code from user-defined configuration & schema files
* `local` — Prepare local environment for envio testing
* `start` — Start the indexer without any automatic codegen

###### **Options:**

* `-d`, `--directory <DIRECTORY>` — The directory of the project. Defaults to current dir ("./")
* `-o`, `--output-directory <OUTPUT_DIRECTORY>` — The directory within the project that generated code should output to

  Default value: `generated/`
* `--config <CONFIG>` — The file in the project containing config

  Default value: `config.yaml`



## `envio init`

Initialize an indexer with one of the initialization options

**Usage:** `envio init [OPTIONS] [COMMAND]`

###### **Subcommands:**

* `template` — Initialize from an example template
* `subgraph-migration` — Initialize by migrating config from an existing subgraph
* `contract-import` — Initialize by importing config from a contract for a given chain

###### **Options:**

* `-n`, `--name <NAME>` — The name of your project
* `-l`, `--language <LANGUAGE>` — The language used to write handlers

  Possible values: `javascript`, `typescript`, `rescript`




## `envio init template`

Initialize from an example template

**Usage:** `envio init template [OPTIONS]`

###### **Options:**

* `-t`, `--template <TEMPLATE>` — Name of the template to be used in initialization

  Possible values: `greeter`, `erc20`




## `envio init subgraph-migration`

Initialize by migrating config from an existing subgraph

**Usage:** `envio init subgraph-migration [OPTIONS]`

###### **Options:**

* `-s`, `--subgraph-id <SUBGRAPH_ID>` — Subgraph ID to start a migration from



## `envio init contract-import`

Initialize by importing config from a contract for a given chain

**Usage:** `envio init contract-import [OPTIONS] [COMMAND]`

###### **Subcommands:**

* `explorer` — Initialize by migrating config from an existing subgraph
* `local` — Initialize from an example template

###### **Options:**

* `-c`, `--contract-address <CONTRACT_ADDRESS>` — Contract address to generate the config from



## `envio init contract-import explorer`

Initialize by migrating config from an existing subgraph

**Usage:** `envio init contract-import explorer [OPTIONS]`

###### **Options:**

* `-b`, `--blockchain <BLOCKCHAIN>` — Network from which contract address should be fetched for migration

  Possible values: `ethereum-mainnet`, `goerli`, `optimism`, `base`, `bsc`, `gnosis`, `polygon`, `optimism-goerli`, `arbitrum-one`, `arbitrum-goerli`, `avalanche`, `mumbai`, `sepolia`, `linea`




## `envio init contract-import local`

Initialize from an example template

**Usage:** `envio init contract-import local [OPTIONS]`

###### **Options:**

* `-a`, `--abi-file <ABI_FILE>` — The path to a json abi file
* `--contract-name <CONTRACT_NAME>` — The name of the contract
* `-b`, `--blockchain <BLOCKCHAIN>` — Network from which contract address should be fetched for migration
* `-r`, `--rpc-url <RPC_URL>` — The rpc url to use if the network id used is unsupported by our hypersync



## `envio dev`

Development commands for starting, stopping, and restarting the indexer with automatic codegen for any changed files

**Usage:** `envio dev`



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

* `docker` — Local Envio and ganache environment commands
* `db-migrate` — Local Envio database commands



## `envio local docker`

Local Envio and ganache environment commands

**Usage:** `envio local docker <COMMAND>`

###### **Subcommands:**

* `up` — Create docker images required for local environment
* `down` — Delete existing docker images on local environment



## `envio local docker up`

Create docker images required for local environment

**Usage:** `envio local docker up`



## `envio local docker down`

Delete existing docker images on local environment

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

Start the indexer without any automatic codegen

**Usage:** `envio start [OPTIONS]`

###### **Options:**

* `-r`, `--restart` — Clear your database and restart indexing from scratch



<hr/>

<small><i>
    This document was generated automatically by
    <a href="https://crates.io/crates/clap-markdown"><code>clap-markdown</code></a>.
</i></small>

