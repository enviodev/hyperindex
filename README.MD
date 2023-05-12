# Envio

Envio is an indexing solution that allows web3 projects to access data on any EVM-compatible chain.

Aim of Envio is to optimize developer experience of using an indexer, whilst providing fast, secure and reliable indexing service.
# Getting Started
## Installation

Install prerequisite tools:
1. Node.js (install v18) https://nodejs.org/en
   (Recommended to use a node manager like fnm or nvm)
2. pnpm:
   Run `npm install --global pnpm`
3. Cargo https://doc.rust-lang.org/cargo/getting-started/installation.html
   Run `curl https://sh.rustup.rs -sSf | sh`
4. Docker Desktop https://www.docker.com/products/docker-desktop/

Install Envio:
1. Run 
```
cargo install --path codegenerator`
```
2. Run 
```
envio --help
```
   to see available CLI commands

## Create templates

`cd` into folder of your choice and run 
```
envio init
```
to get a Gravatar template for configuration, schema and EventHandlers files.

## Configure the files according to your project

[Here](codegenerator/templates/static/gravatar_template/shared/README.md) is an example of how to configure the files for indexing.

## Generate code according to configuration

Once you have configured the above files, the following can be used generate all the code that is required for indexing your project:

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
## Build

```
pnpm run build
```

## Watch

```
pnpm run watch
```
