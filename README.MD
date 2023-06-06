# Envio

Envio is a reliable real-time indexing solution that makes it easy to ingest events from EVM-compatible chains and process that data into to custom APIs. These APIs are perfect for unlocking slick user-experiences in blockchain application frontends.

Aim of Envio is to optimize developer experience of using an indexer, whilst providing fast, secure and reliable indexing service.
# CLI tool

This repo uses `clap` CLI library.

Help file for CLI commands can be found [here](codegenerator/CommandLineHelp.md)

# Getting Started
## Installation

Install prerequisite tools:
1. Node.js (install v18) https://nodejs.org/en
   (Recommended to use a node manager like fnm or nvm)
2. pnpm
   ```
   npm install --global pnpm
   ```
3. Cargo https://doc.rust-lang.org/cargo/getting-started/installation.html
   Run `curl https://sh.rustup.rs -sSf | sh`
4. Docker Desktop https://www.docker.com/products/docker-desktop/

Install Envio:
```
cargo install --path codegenerator`
```


Command to see available CLI commands
```
envio --help
```

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
Then choose a language from Javascript, Typescript or Rescript to write the event handlers file.
```
? Which language would you like to use?  
> "Javascript"
  "Typescript"
  "Rescript"
[↑↓ to move, enter to select, type to filter
```

This will generate the config, schema and event handlers files according to the template and language chosen.

## Configure the files according to your project

[Here](codegenerator/templates/static/gravatar_template/shared/README.md) is an example of how to configure the files for indexing.

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

