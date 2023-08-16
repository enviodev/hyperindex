# Envio CLI tool

A fast, reliable, customizable indexing blockchain solution.

Envio is a reliable real-time indexing solution designed to simplify the ingestion of events from EVM-compatible chains and transform this data into custom GraphQL APIs. These APIs play a pivotal role in enabling seamless user experiences in blockchain application front-ends. With Envio, the emphasis is on refining the developer's experience when using an indexer, ensuring the service is swift, secure, and trustworthy.

*Note: For a thorough understanding and to dive deeper into each feature, refer to the original [documentation website](https://docs.envio.dev).*

## Table of Contents

<!-- TODO: features summary will be nice to add -->
<!-- - [Features](#features) -->
- [Quickstart](#quickstart)
- [Installation](#installation)
- [Usage](#usage)
- [Event Handlers](#event-handlers)
- [Logging](#logging)
- [Contribution & Support](#contribution-&-support)

*Note: Envio is built for javascript, typescirpt and rescript. However in this readme we will only use typescript for examples. Refer to the [documentation website](https://docs.envio.dev) for full docs.*
## [Quickstart](https://docs.envio.dev/docs/quickstart)

For a slightly larger tutorial please see the [Greeter contract tutorial](https://docs.envio.dev/docs/greeter-tutorial).

## [Installation](https://docs.envio.dev/docs/installation)
### Prerequisites
- [Node.js](https://nodejs.org/en/download/current)
- [pnpm](https://pnpm.io/installation) on [npm](https://www.npmjs.com/get-npm)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)

To install the `envio` tool globally, run:

```bash
npm i -g envio
```

To view the available CLI commands:

```bash
npx envio --help
```

## Usage

**Important Commands Overview:**
- `envio`
- `envio init` - Auto-generates configuration, GraphQL schema, and event handlers based on the Greeter template.
- `envio codegen` - Generates code after setting configuration and schema files.
- `envio start`
- `envio local docker up`
- `envio local docker down`
- `envio local db-migrate setup`

For a detailed breakdown of commands, refer to the [documentation](https://docs.envio.dev/docs/cli-commands).

## Event Handlers

After establishing the configuration and schema files, execute:

```bash
npx envio codegen
```

Custom code to make it easy to retrieve and process events from our contract is generated. More specifically every event necessitates the registration of two core functions from our generated code:
- Loader function
- Handler function

### Loader Function

Loader functions are responsible for loading specific entities (defined in `schema.graphql`) to be modified by the event. They are called in the following format:

```typescript
<ContractName>Contract_ < EventName > _loader;
```

### Handler Function

Handler functions modify the entities loaded by the loader function. They incorporate the essential logic for updating entities with the raw data produced by the event. They're called as:

```typescript
<ContractName>Contract_ < EventName > _handler;
```

For a comprehensive guide on Event Handlers, please refer to the [provided documentation](https://docs.envio.dev/docs/event-handlers).

## Logging

Logging is integral for tracking the progress and debugging issues in the indexer. Envio utilizes the [pino](https://github.com/pinojs/pino/) logging library, which can be integrated with tools like [kibana](https://www.elastic.co/what-is/kibana) to extract metrics and insights.

For user-level logging, context-based functions are provided:
- `<context>.log.debug`
- `<context>.log.info`
- `<context>.log.warn`
- `<context>.log.error`
- `<context>.log.errorWithExn`

Further details about developer logging, including log levels, can be found in the [documentation](https://docs.envio.dev/docs/logging).

## Contribution & Support

🔧 This product under active development. Please always refer to the main documentation for the latest updates.

For support and updates, follow Envio on [Twitter](https://twitter.com/envio_indexer) or join the [Discord community](https://discord.gg/DhfFhzuJQh). 

If you have specific suggestions or requirements, kindly reach out and contribute to the development of Envio.

Our [common issues](https://docs.envio.dev/docs/common-issues) page may also have useful help for you
