## Indexer Requirements

The following files are required to use the Indexer:

- Configuration (defaults to `config.yaml`)
- GraphQL Schema (defaults to `schema.graphql`)
- Event Handlers (defaults to `src/EventHandlers.*` depending on flavour chosen) 

These files are auto-generated according to the Gravatar template by running `envio init` command.

## Config File Setup

Example config file from Gravatar scenario:

```yaml
version: 0.0.0
description: Gravatar for Ethereum
repository: https://github.com/graphprotocol/example-subgraph
networks:
  - id: 137
    rpc_url: https://polygon-rpc.com
    start_block: 34316032
    contracts:
      - name: Gravatar
        abi_file_path: abis/gravatar-abi.json
        address: ["0x2E645469f354BB4F5c8a05B3b30A929361cf77eC"]
        handler: ./src/EventHandlers.bs.js
        events:
          - name: "NewGravatar"
            requiredEntities: []
          - name: "UpdatedGravatar"
            requiredEntities:
              - name: "Gravatar"
                labels:
                  - "gravatarWithChanges"
```

**Field Descriptions**

- `version` - Version of the indexer
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

Example schema definition for Gravatar scenario:

```graphql
type Gravatar @entity {
  id: ID!
  owner: Bytes!
  displayName: String!
  imageUrl: String!
  updatesCount: Int!
}
```

## Writing Event Handlers

Once the configuration and graphQL schema files are in place, run
```
envio codegen
``` 
in the project directory.

The entity and event types will then be available in the handler files. 

A user can specify a specific handler file per contract that processes events emitted by that contract.
Each event handler requires two functions to be registered in order to enable full functionality within the indexer.
1. An `<event>LoadEntities` function
2. An `<event>Handler` function

### Example of registering a `loadEntities` function for the `UpdatedGravatar` event from the above example config:

```rescript
Handlers.GravatarContract.registerUpdatedGravatarLoadEntities((event, contextUpdator) => {
  contextUpdator.gravatar.gravatarWithChangesLoad(event.params.id->Ethers.BigInt.toString)
})
```

Inspecting the config of the `UpdatedGravatar` event from the above example config indicates that there is a defined `requiredEntities` field of the following:

```yaml
events:
  - name: "UpdatedGravatar"
    requiredEntities:
      - name: "Gravatar"
        labels:
          - "gravatarWithChanges"
```

- The register function `registerUpdatedGravatarLoadEntities` follows a naming convention for all events: `register<EventName>LoadEntities`. 
- Within the function that is being registered the user must define the criteria for loading the `gravatarWithChanges` entity which corresponds to the label defined in the config. 
- This is made available to the user through the load entity context defined as `contextUpdator`.
- In the case of the above example the `gravatarWithChanges` loads a `Gravatar` entity that corresponds to the id received from the event.

### Example of registering a `Handler` function for the `UpdatedGravatar` event and using the loaded entity `gravatarWithChanges`:

```rescript
Handlers.GravatarContract.registerUpdatedGravatarHandler((event, context) => {
  let updatesCount =
    context.gravatar.gravatarWithChanges()->Belt.Option.mapWithDefault(1, gravatar =>
      gravatar.updatesCount + 1
    )

  let gravatar: gravatarEntity = {
    id: event.params.id->Ethers.BigInt.toString,
    owner: event.params.owner->Ethers.ethAddressToString,
    displayName: event.params.displayName,
    imageUrl: event.params.imageUrl,
    updatesCount,
  }

  context.gravatar.update(gravatar)
})
```

- The handler functions also follow a naming convention for all events in the form of: `register<EventName>Handler`.
- Once the user has defined their `loadEntities` function, they are then able to retrieve the loaded entity information via the labels defined in the `config.yaml` file. 
- In the above example, if a `Gravatar` entity is found matching the load criteria in the `loadEntities` function, it will be available via `gravatarWithChanges`. 
- This is made available to the user through the handler context defined simply as `context`. 
- This `context` is the gateway by which the user can interact with the indexer and the underlying database.
- The user can then modify this retrieved entity and subsequently update the `Gravatar` entity in the database. 
- This is done via the `context` using the update function (`context.gravatar.update(gravatar)`).
- The user has access to a `gravatarEntity` type that has all the fields defined in the schema.

This context also provides the following functions per entity that can be used to interact with that entity:

- insert
- update
- delete
