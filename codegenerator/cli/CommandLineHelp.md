# Command-Line Help for `envio`

This document contains the help content for the `envio` command-line program.

**Command Overview:**

* [`envio`↴](#envio)
* [`envio init`↴](#envio-init)
* [`envio dev`↴](#envio-dev)
* [`envio stop`↴](#envio-stop)
* [`envio codegen`↴](#envio-codegen)
* [`envio start`↴](#envio-start)

## `envio`

**Usage:** `envio <COMMAND>`

###### **Subcommands:**

* `init` — Initialize a project with a template
* `dev` — Development commands for starting, stopping, and restarting the local environment
* `stop` — Stop the local environment - delete the database and stop all processes (including Docker) for the current directory
* `codegen` — Generate code from a config.yaml & schema.graphql file
* `start` — Start the indexer



## `envio init`

Initialize a project with a template

**Usage:** `envio init [OPTIONS]`

###### **Options:**

* `-d`, `--directory <DIRECTORY>` — The directory of the project
* `-n`, `--name <NAME>`
* `-t`, `--template <TEMPLATE>` — The file in the project containing config

  Possible values: `blank`, `greeter`, `erc20`

* `-s`, `--subgraph-migration <SUBGRAPH_MIGRATION>` — Subgraph ID to start a migration from
* `-l`, `--language <LANGUAGE>`

  Possible values: `javascript`, `typescript`, `rescript`




## `envio dev`

Development commands for starting, stopping, and restarting the local environment

**Usage:** `envio dev`



## `envio stop`

Stop the local environment - delete the database and stop all processes (including Docker) for the current directory

**Usage:** `envio stop`



## `envio codegen`

Generate code from a config.yaml & schema.graphql file

**Usage:** `envio codegen [OPTIONS]`

###### **Options:**

* `-d`, `--directory <DIRECTORY>` — The directory of the project

  Default value: `.`
* `-o`, `--output-directory <OUTPUT_DIRECTORY>` — The directory within the project that generated code should output to

  Default value: `generated/`
* `-c`, `--config <CONFIG>` — The file in the project containing config

  Default value: `config.yaml`



## `envio start`

Start the indexer

**Usage:** `envio start [OPTIONS]`

###### **Options:**

* `-r`, `--restart` — Clear your database and restart indexing from scratch

  Default value: `false`
* `-d`, `--directory <DIRECTORY>` — The directory of the project

  Default value: `.`



<hr/>

<small><i>
    This document was generated automatically by
    <a href="https://crates.io/crates/clap-markdown"><code>clap-markdown</code></a>.
</i></small>

