## Indexer Config

The following files are required for the Indexer:

- config file (defaults to config.yaml)
- graphql schema (defaults to schema.graphql)
- handler files (files that process event data into entities defined in the schema)

### Config File Setup

example config file from Gravatar scenario:

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
        address: ["0x3E645469f354BB4F5c8a05B3b30A929361cf77eC"]
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

- version - version of the indexer
- description - description of the project
- repository - repository of the project
- networks - configuration of the blockchain networks that the project is deployed on
  - id - chain identifier of the network
  - rpc_url - rpc url that will be used to subscribe to blockchain data on this network
  - start_block - initial block from which the indexer will start listening for events
  - contracts - configuration for each contract deployed on the network
    - name - user defined contract name
    - abi_file_path - file location of the contract abi
    - address - an array of addresses that the contract is deployed to on the network
    - handler - location of the file that handles the events emitted by this contract
    - events - configuration for each event emitted by this contract that the indexer will listen for
      - name - name of the event (must match the name in the abi)
      - required_entities - an array of entities that need to loaded and made accesible within the handler function (an empty array indicates that no entities are required)
        - name - the name of the required entity (must match an entity defined in the schema)
        - label - a user defined label that corresponds to this entity load

### Schema Definition

The schema.grapql file contains the definitions of all user defined entities. These entity types are then created/modified within the handler files.

example schema definition for Gravatar scenario:

```graphql
type Gravatar @entity {
  id: ID!
  owner: Bytes!
  displayName: String!
  imageUrl: String!
  updatesCount: Int!
}
```

## Writing Handlers

Once the above configuration files are in place, run:
`envio codegen`

The entity and event types will then be available in the handler files.

A user can specifiy a specific handler file per contract that processes events emitted by that contract.
Each event handler requires two functions to be registered in order to enable full functionality within the indexer.
The required functions to be registered are:

- An `<event>LoadEntities` function
- An `<event>Handler` function

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

The register function `registerUpdatedGravatarLoadEntities` follows a naming convention for all events: `register<EventName>LoadEntities`. Within the function that is being registered the user must define the criteria for loading the `gravatarWithChanges` entity which corresponds to the label defined in the config. This is made available to the user through the load entity context defined as `contextUpdator`.

In the case of the above example the `gravatarWithChanges` loads a `Gravatar` entity that corresponds to the id received from the event.

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

The handler functions also follow a naming convention for all events in the form of: `register<EventName>Handler`.
Once the user has defined their `loadEntities` function they are then able to retrieve the loaded entity information via the labels defined in the config.yaml file. In the above example, if a `Gravatar` entity is found matching the load criteria in the `loadEntities` function, it will be available via `gravatarWithChanges`. This is made available to the user through the handler context defined simply as `context`. This context is the gateway by which the user can interact with the indexer and the underlying database.
The user can then modify this retrieved entity and subsequently update the `Gravatar` entity in the database. This is done via the context using the update function (`context.gravatar.update(gravatar)`).
The user has access to a `gravatarEntity` type that has all the fields defined in the schema.

This context also provides the following functions per entity that can be used to interact with that entity:

- insert
- update
- delete

# Code generation and running the scenario

Once the user has defined the above config and handler files, the following can be used to run the indexer on the scenario

Run from this directory:

```bash

envio codegen
docker compose up -d # NOTE: if you have some stale data, run "docker compose down -v" first.
pnpm start
```

To view the data in the database, run `./generated/register_tables_with_hasura.sh` and open http://localhost:8080/console.

Alternatively you can open the file `index.html` for a cleaner experience (no hasura stuff). Unfortunately, hasura currently isn't configured to make the data public.

## Build

```

pnpm run build

```

# Watch

```

pnpm run watch

```

```

```

# Deploying the nft-factory to the cluster with waypoint 

ensure you are familiar with waypoint and kubernetes: https://developer.hashicorp.com/waypoint/tutorials/get-started-kubernetes/get-started-kubernetes

ensure you have access to desired cluster. 

run the following steps if you are setting up for the first time: 

- waypoint install --platform=kubernetes -accept-tos
- waypoint init

build the indexer with fuji config:
- pnpm codegen-fuji -s

Update the container image tag and any environment variables in the application section of the waypoint.hcl file

deploy using waypoint: 
- waypoint up

Alternatively, if you wish to run the nft-factory indexer using docker locally instead of deploying to a cluster, you can use the docker compose file in this directory:
- docker compose up -d


