## Open Zepplin ERC-20

Install Open Zepplin contracts by running the following:

```
npm install @openzeppelin/contracts
```

Custom `Creation` event has been added to the standard contract as an example.

## Indexer Requirements

The following files are required to use the Indexer:

- Configuration (defaults to `config.yaml`)
- GraphQL Schema (defaults to `schema.graphql`)
- Event Handlers (defaults to `src/EventHandlers.*` depending on flavour chosen) 

These files are auto-generated according to the ERC-20 template by running `envio init` command.

## Config File Setup

Example config file from ERC-20 scenario:

```yaml
version: 1.0.0
description: ERC-20 indexer
repository: https://github.com/PaulRBerg/hardhat-template
networks:
  - id: 1337
    rpc_url: http://localhost:8545
    start_block: 0
    contracts:
      - name: ERC20
        abi_file_path: abis/erc20-abi.json
        address: ["0x2B502ab6F783c2Ae96A75dc68cf82a77ce2637c2"]
        handler: ./src/EventHandlers.bs.js
        events:
          - name: "NewGreeting"
            requiredEntities:
              - name: "Greeting"
                labels:
                  - "greetingWithChanges"
          - name: "ClearGreeting"
            requiredEntities:
              - name: "Greeting"
                labels:
                  - "greetingWithChanges"

```

**Field Descriptions**

- `version` - Version of the config schema used by the indexer
- `description` - Description of the project
- `repository` - Repository of the project
- `networks` - Configuration of the blockchain networks that the project is deployed on
  - `id` - Chain identifier of the network
  - `rpc_url` - RPC URL that will be used to subscribe to blockchain data on this network
  - `start_block` - Initial block from which the indexer will start listening for events
  - `contracts` - Configuration for each contract deployed on the network
    - `name` - User-defined contract name
    - `abi_file_path` - File location of the contract ABI
    - `address` - An array of addresses that the contract is deployed to on the network
    - `handler` - Location of the file that handles the events emitted by this contract
    - `events` - Configuration for each event emitted by this contract that the indexer will listen for
      - `name` - Name of the event (must match the name in the ABI)
      - `required_entities` - An array of entities that need to loaded and made accessible within the handler function (an empty array indicates that no entities are required)
        - `name` - The name of the required entity (must match an entity defined in `schema.graphql`)
        - `label` - A user defined label that corresponds to this entity load

### Schema Definition

The `schema.graphql` file contains the definitions of all user-defined entities. These entity types are then created/modified within the handler files.

Example schema definition for ERC-20 scenario:

```graphql
type Greeting @entity {
  id: ID!
  latestGreeting: String!
  numberOfGreetings: Int!
}

```

## Writing Event Handlers

Once the configuration and graphQL schema files are in place, run
```bash
envio codegen
``` 
in the project directory.

The entity and event types will then be available in the handler files. 

A user can specify a specific handler file per contract that processes events emitted by that contract.
Each event handler requires two functions to be registered in order to enable full functionality within the indexer.
1. An `<event>LoadEntities` function
2. An `<event>Handler` function

### Example of registering a `loadEntities` function for the `NewGreeting` event from the above example config:

```rescript
Handlers.ERC20Contract.registerNewGreetingLoadEntities((~event, ~context) => {
  context.greeting.greetingWithChangesLoad(event.params.user->Ethers.ethAddressToString)
})
```

Inspecting the config of the `NewGreeting` event from the above example config indicates that there is a defined `requiredEntities` field of the following:

```yaml
events:
  - name: "NewGreeting"
    requiredEntities:
      - name: "Greeting"
        labels:
          - "greetingWithChanges"
```

- The register function `registerNewGreetingLoadEntities` follows a naming convention for all events: `register<EventName>LoadEntities`. 
- Within the function that is being registered the user must define the criteria for loading the `greetingWithChanges` entity which corresponds to the label defined in the config. 
- This is made available to the user through the load entity context defined as `contextUpdator`.
- In the case of the above example the `greetingWithChanges` loads a `Greeting` entity that corresponds to the id received from the event.

### Example of registering a `Handler` function for the `NewGreeting` event and using the loaded entity `greetingWithChanges`:

```rescript
Handlers.ERC20Contract.registerNewGreetingHandler((~event, ~context) => {
  let currentERC20Opt = context.greeting.greetingWithChanges()

  switch currentERC20Opt {
  | Some(existingERC20) => {
      let greetingObject: greetingEntity = {
        id: event.params.user->Ethers.ethAddressToString,
        latestGreeting: event.params.greeting,
        numberOfGreetings: existingERC20.numberOfGreetings + 1,
      }

      context.greeting.update(greetingObject)
    }

  | None =>
    let greetingObject: greetingEntity = {
      id: event.params.user->Ethers.ethAddressToString,
      latestGreeting: event.params.greeting,
      numberOfGreetings: 1,
    }

    context.greeting.insert(greetingObject)
  }
})
```

- The handler functions also follow a naming convention for all events in the form of: `register<EventName>Handler`.
- Once the user has defined their `loadEntities` function, they are then able to retrieve the loaded entity information via the labels defined in the `config.yaml` file. 
- In the above example, if a `Greeting` entity is found matching the load criteria in the `loadEntities` function, it will be available via `greetingWithChanges`. 
- This is made available to the user through the handler context defined simply as `context`. 
- This `context` is the gateway by which the user can interact with the indexer and the underlying database.
- The user can then modify this retrieved entity and subsequently update the `Greeting` entity in the database. 
- This is done via the `context` using the update function (`context.ERC20.update(greetingObject)`).
- The user has access to a `greetingEntity` type that has all the fields defined in the schema.

This context also provides the following functions per entity that can be used to interact with that entity:

- insert
- update
- delete
