# Command-Line Help for `envio`

This document contains the help content for the `envio` command-line program.

**Command Overview:**

* [`envio`↴](#envio)
* [`envio init`↴](#envio-init)
* [`envio codegen`↴](#envio-codegen)
* [`envio local`↴](#envio-local)
* [`envio local docker`↴](#envio-local-docker)
* [`envio local db-migrate`↴](#envio-local-db-migrate)

## `envio`

**Usage:** `envio <COMMAND>`

###### **Subcommands:**

* `init` — Initialize a project with a template
* `codegen` — Generate code from a config.yaml file
* `local` — Run local docker instance of indexer



## `envio init`

Initialize a project with a template

**Usage:** `envio init [OPTIONS]`

###### **Options:**

* `-d`, `--directory <DIRECTORY>` — The directory of the project

  Default value: `./`
* `-t`, `--template <TEMPLATE>` — The file in the project containing config

  Possible values: `blank`, `greeter`, `erc20`

* `-l`, `--language <LANGUAGE>`

  Possible values: `javascript`, `typescript`, `rescript`




## `envio codegen`

Generate code from a config.yaml file

**Usage:** `envio codegen [OPTIONS]`

###### **Options:**

* `-d`, `--directory <DIRECTORY>` — The directory of the project

  Default value: `./`
* `-o`, `--output-directory <OUTPUT_DIRECTORY>` — The directory within the project that generated code should output to

  Default value: `generated/`
* `-c`, `--config <CONFIG>` — The file in the project containing config

  Default value: `config.yaml`



## `envio local`

Run local docker instance of indexer

**Usage:** `envio local <COMMAND>`

###### **Subcommands:**

* `docker` — Local Envio and ganache environment commands
* `db-migrate` — Local Envio database commands



## `envio local docker`

Local Envio and ganache environment commands

**Usage:** `envio local docker [OPTIONS]`

###### **Options:**

* `-u`, `--up` — Start local docker postgres and ganache instance for indexer
* `-d`, `--down` — Drop local docker postgres and ganache instance for indexer



## `envio local db-migrate`

Local Envio database commands

**Usage:** `envio local db-migrate [OPTIONS]`

###### **Options:**

* `-u`, `--up` — Migrate latest schema to database
* `-d`, `--down` — Drop database schema
* `-s`, `--setup` — Setup DB



<hr/>

<small><i>
    This document was generated automatically by
    <a href="https://crates.io/crates/clap-markdown"><code>clap-markdown</code></a>.
</i></small>

