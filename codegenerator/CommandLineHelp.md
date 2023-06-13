# Command-Line Help for `envio`

This document contains the help content for the `envio` command-line program.

**Command Overview:**

* [`envio`↴](#envio)
* [`envio init`↴](#envio-init)
* [`envio codegen`↴](#envio-codegen)
* [`envio local`↴](#envio-local)
* [`envio local docker`↴](#envio-local-docker)
* [`envio local docker up`↴](#envio-local-docker-up)
* [`envio local docker down`↴](#envio-local-docker-down)
* [`envio local db-migrate`↴](#envio-local-db-migrate)
* [`envio local db-migrate up`↴](#envio-local-db-migrate-up)
* [`envio local db-migrate down`↴](#envio-local-db-migrate-down)
* [`envio local db-migrate setup`↴](#envio-local-db-migrate-setup)

## `envio`

**Usage:** `envio <COMMAND>`

###### **Subcommands:**

* `init` — Initialize a project with a template
* `codegen` — Generate code from a config.yaml file
* `local` — Prepare local environment for envio testing



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

Prepare local environment for envio testing

**Usage:** `envio local <COMMAND>`

###### **Subcommands:**

* `docker` — Local Envio and ganache environment commands
* `db-migrate` — Local Envio database commands



## `envio local docker`

Local Envio and ganache environment commands

**Usage:** `envio local docker <COMMAND>`

###### **Subcommands:**

* `up` — Run docker compose up -d on generated/docker-compose.yaml
* `down` — Run docker compose down -v on generated/docker-compose.yaml



## `envio local docker up`

Run docker compose up -d on generated/docker-compose.yaml

**Usage:** `envio local docker up`



## `envio local docker down`

Run docker compose down -v on generated/docker-compose.yaml

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



<hr/>

<small><i>
    This document was generated automatically by
    <a href="https://crates.io/crates/clap-markdown"><code>clap-markdown</code></a>.
</i></small>

