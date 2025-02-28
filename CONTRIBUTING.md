## Installation

Install prerequisite tools:

1. Node.js (install v18) https://nodejs.org/en
   (Recommended to use a node manager like fnm or nvm)
2. pnpm

   ```sh
   npm install --global pnpm
   ```

3. Cargo https://doc.rust-lang.org/cargo/getting-started/installation.html

   ```sh
   curl https://sh.rustup.rs -sSf | sh
   ```

4. Docker Desktop https://www.docker.com/products/docker-desktop/

Install Envio:

```sh
cargo install --path codegenerator/cli --locked --debug
```

Command to see available CLI commands

```sh
envio --help
```

Alternatively you can add an alias in your shell config. This will allow you to test Envio locally without manual recompiling.

Go to your shell config file and add the following line:

```sh
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

```sh
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

Our greeter template [config.yaml](./codegenerator/cli/templates/static/greeter_template/typescript/config.yaml) and [schema.graphql](./codegenerator/cli/templates/static/greeter_template/shared/schema.graphql) is an example of how to layout a configuration file for indexing.

_Please refer to the [documentation website](https://docs.envio.dev) for a thorough guide on all [Envio](https://envio.dev) indexer features_

## Generate code according to configuration

Once you have configured the above files and deployed the contracts, the following can be used generate all the code that is required for indexing your project:

```sh
envio codegen
```

## Run the indexer

Once all the configuration files and auto-generated files are in place, you are ready to run the indexer for your project:

```sh
pnpm start
```

## View the database

To view the data in the database open http://localhost:8080/console.

Admin-secret for local Hasura is `testing`.
