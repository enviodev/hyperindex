# HyperIndex

HyperIndex is a modern, multi-chain data indexing framework for efficiently querying real-time and historical data from any EVM blockchain and Fuel.

Designed with a core focus on delivering superior performance and seamless developer experience, HyperIndex optimizes the user experience.

Build a real-time API for your blockchain application in minutes.

## Key Features

- Simple installation & Setup
- Any EVM blockchain, as well as Fuel
- The fastest historical sync
- Real-time indexing with reorg handling
- Multi-chain support
- Write JavaScript, TypeScript, or ReScript with automatically generated types
- Detailed logging & Error messaging
- [Hosted Service](https://docs.envio.dev/docs/HyperIndex/hosted-service) to take care of your infrastructure

## Installation

Install prerequisite tools:

1. Node.js (install v18) https://nodejs.org/en
   (Recommended to use a node manager like fnm or nvm)
2. pnpm

   ```
   npm install --global pnpm
   ```

3. Cargo https://doc.rust-lang.org/cargo/getting-started/installation.html

   ```
   curl https://sh.rustup.rs -sSf | sh
   ```

4. Docker Desktop https://www.docker.com/products/docker-desktop/

Install Envio:

```
cargo install --path codegenerator/cli --locked --debug
```

Command to see available CLI commands

```
envio --help
```

Alternatively you can add an alias in your shell config. This will allow you to test Envio locally without manual recompiling.

Go to your shell config file and add the following line:

```
alias lenvio="cargo run --manifest-path <absolute repository path>/hyperindex/codegenerator/cli/Cargo.toml --"
```

> `lenvio` is like `local envio` 😁

## Update CLI Generated Docs

Navigate to the cli directory
`cd codegenerator/cli`

To update all generated docs run

`make update-generated-docs`

To updated just the config json schemas
`make update-schemas`

Or to update just the cli help md file
`update-help`

## Create templates

`cd` into folder of your choice and run

```
envio init
```

Then choose a template out of the possible options

```
? Which template would you like to use?
> "Gravatar"
[↑↓ to move, enter to select, type to filter]
```

Then choose a language from JavaScript, TypeScript or ReScript to write the event handlers file.

```
? Which language would you like to use?
> "JavaScript"
  "TypeScript"
  "ReScript"
[↑↓ to move, enter to select, type to filter
```

This will generate the config, schema and event handlers files according to the template and language chosen.

## Configure the files according to your project

[Here](codegenerator/templates/static/greeter_template/typescript/README.md) is an example of how to configure the files for indexing.

## Generate code according to configuration

Once you have configured the above files and deployed the contracts, the following can be used generate all the code that is required for indexing your project:

```
envio codegen
```

## Run the indexer

Once all the configuration files and auto-generated files are in place, you are ready to run the indexer for your project:

```
pnpm start
```

## View the database

To view the data in the database, run

```
./generated/register_tables_with_hasura.sh
```

and open http://localhost:8080/console.

Admin-secret for local Hasura is `testing`

Alternatively you can open the file `index.html` for a cleaner experience (no Hasura stuff). Unfortunately, Hasura is currently not configured to make the data public.

# Local testing using Hardhat and Docker

Below are steps to be followed when testing the indexer locally using Hardhat and Docker.

NB: All the files must be configured as per guideline above.

1. Removing stale data

   ```
   docker-compose down -v
   ```

2. Restarting docker

   ```
   docker-compose up -d
   ```

3. Deploying contract

   ```
   cd contracts
   rm -r deployments
   pnpm hardhat deploy
   ```

   Note that this will delete the previous deployment of the smart contract and re-deploy to prevent `node synced status` errors.

   More information on how to deploy contracts using Hardhat can be found [here](https://hardhat.org/hardhat-runner/docs/guides/deploying).

4. Generating code
   Once you are in your project directory, run:

   ```
   envio codegen
   ```

5. Running the indexer

   ```
   pnpm start
   ```

6. Running some tasks

   ```
   pnpm hardhat task:1 --parameter-1 value-1
   ```

   More information on how to create and run tasks using Hardhat can be found [here](https://hardhat.org/hardhat-runner/docs/advanced/create-task).

7. Checking the results on local Hasura
   ```
   ./generated/register_tables_with_hasura.sh
   ```
   and open http://localhost:8080/console.

# Troubleshooting

## Exporting smart contract ABI

If you have updated your smart contract after the initial codegen, then you will have to recreate the ABI for your smart contract.

Run

```
cd contracts
pnpm hardhat export-abi
```

Ensure that the directory for ABI in config.yaml is pointing to the correct folder where ABIs have been freshly generated.
