# Command-Line Help for `envio`

This document contains the help content for the `envio` command-line program.

**Command Overview:**

* [`envio`↴](#envio)
* [`envio init`↴](#envio-init)
* [`envio codegen`↴](#envio-codegen)

## `envio`

**Usage:** `envio <COMMAND>`

###### **Subcommands:**

* `init` — Initialize a project with a template
* `codegen` — Generate code from a config.yaml file



## `envio init`

Initialize a project with a template

**Usage:** `envio init [OPTIONS]`

###### **Options:**

* `-d`, `--directory <DIRECTORY>` — The directory of the project

  Default value: `./`
* `-t`, `--template <TEMPLATE>` — The file in the project containing config

  Possible values: `gravatar`

* `-f`, `--js-flavor <JS_FLAVOR>`

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



<hr/>

<small><i>
    This document was generated automatically by
    <a href="https://crates.io/crates/clap-markdown"><code>clap-markdown</code></a>.
</i></small>

