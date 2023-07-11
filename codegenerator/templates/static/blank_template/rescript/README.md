## Indexer Requirements

The following files are required to use the Indexer:

- Configuration (defaults to `config.yaml`)
- GraphQL Schema (defaults to `schema.graphql`)
- Event Handlers (defaults to `src/EventHandlers.res`) 

These files are auto-generated according to the Greeter template by running `envio init` command.

## Config File Setup

Example config file from Greeter scenario:

```yaml
name: NameOfTheIndexer
version: 0.0.1 # Version of the config schema used by the indexer
description: My Awesome Contract # Description of the project
networks: # Configuration of the blockchain networks that the project is deployed on
  - id: 1337 # Chain identifier of the network
    rpc_config: 
      url: http://localhost:8545 # RPC URL that will be used to subscribe to blockchain data on this network
    start_block: 0 # Initial block from which the indexer will start listening for events
    contracts: # Configuration for each contract 
      - name: MyAwesomeContract # User-defined contract name
        abi_file_path: abi/MyAwesomeContract.json # File location of the contract ABI
        address: "0x0000000000000000000000000000000000000000" # An array of addresses that the contract is deployed to on the network
        handler: ./src/EventHandlers.bs.js # Location of the file that handles the events emitted by this contract
        events: # Configuration for each event emitted by this contract that the indexer will listen for
          - event: AwesomeEvent #  Name of the event (must match the name in the ABI)
            requiredEntities: # An array of entities that need to loaded and made accessible within the handler function (an empty array indicates that no entities are required)
              - name: AwesomeEntity # The name of the required entity (must match an entity defined in `schema.graphql`)
                labels: # A user defined label that corresponds to this entity load
                  - awesomeEntityChanges
```

**Field Descriptions**

- `name` - NameOfTheIndexer
- `version` - Version of the config schema used by the indexer
- `description` - Description of the project
- `networks` - Configuration of the blockchain networks that the project is deployed on
  - `id` - Chain identifier of the network
- `rpc_config` - RPC Config that will be used to subscribe to blockchain data on this network
    - `url` -  URL of the RPC endpoint
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

Example schema definition for Greeter scenario:

```graphql
type AwesomeEntity @entity {
  id: ID!
  awesomeField1: String!
  awesomeField2: String!
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

### Example of registering a `loadEntities` function for the `AwesomeEvent` event from the above example config:

```rescript
Handlers.MyAwesomeContract.registerMyAwesomeContractLoadEntities((~event, ~context) => {
    let _ = context.awesomeEvent.awesomeEntityChangesLoad()
})
```

Inspecting the config of the `AwesomeEvent` event from the above example config indicates that there is a defined `requiredEntities` field of the following:

```yaml
  events: # Configuration for each event emitted by this contract that the indexer will listen for
    - event: AwesomeEvent #  Name of the event (must match the name in the ABI)
      requiredEntities: # An array of entities that need to loaded and made accessible within the handler function (an empty array indicates that no entities are required)
        - name: AwesomeEntity # The name of the required entity (must match an entity defined in `schema.graphql`)
          labels: # A user defined label that corresponds to this entity load
            - awesomeEntityChanges
```

- The register function `registerNewGreetingLoadEntities` follows a naming convention for all events: `register<EventName>LoadEntities`. 
- Within the function that is being registered the user must define the criteria for loading the `awesomeEntityChanges` entity which corresponds to the label defined in the config. 
- This is made available to the user through the load entity context defined as `contextUpdator`.
- In the case of the above example the `awesomeEntityChanges` loads a `AwesomeEntity` entity that corresponds to the id received from the event.

### Example of registering a `Handler` function for the `AwesomeEvent` event and using the loaded entity `awesomeEntityChanges`:

```rescript
Handlers.MyAwesomeContract.registerMyAwesomeContractHandler((~event, ~context) => {
    let awesomeEventObject = context.awesomeEvent.awesomeEntityChanges()
    context.awesomeEvent.update(awesomeEventObject)
})
```

- The handler functions also follow a naming convention for all events in the form of: `register<EventName>Handler`.
- Once the user has defined their `loadEntities` function, they are then able to retrieve the loaded entity information via the labels defined in the `config.yaml` file. 
- In the above example, if a `AwesomeEntity` entity is found matching the load criteria in the `loadEntities` function, it will be available via `awesomeEntityChanges`. 
- This is made available to the user through the handler context defined simply as `context`. 
- This `context` is the gateway by which the user can interact with the indexer and the underlying database.
- The user can then modify this retrieved entity and subsequently update the `AwesomeEntity` entity in the database. 
- This is done via the `context` using the update function (`context.awesomeEvent.update(awesomeEventObject)`).
- The user has access to a `AwesomeEntity` type that has all the fields defined in the schema.

This context also provides the following functions per entity that can be used to interact with that entity:

- insert
- update
- delete
