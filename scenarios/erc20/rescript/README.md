## Indexer Requirements

The following files are required to use the Indexer:

- Configuration (defaults to `config.yaml`)
- GraphQL Schema (defaults to `schema.graphql`)
- Event Handlers (defaults to `src/EventHandlers.res`)

These files are auto-generated according to the ERC-20 template by running `envio init` command.

## Config File Setup

Example config file from ERC-20 scenario:

```yaml
name: erc20 indexer
description: ERC-20 indexer
networks:
  - id: 1337
    rpc_config: 
      url: http://localhost:8545
    start_block: 0
    contracts:
      - name: ERC20
        abi_file_path: abis/erc20.json
        address: ["0x61cce07e4cad3bf797667f8fd14d2a7d1582038e"]
        handler: ./src/EventHandlers.bs.js
        events:
          - event: "Approval"
            requiredEntities: 
            - name: "Account"
              labels:
                - "ownerAccountChanges"
          - event: "Transfer"
            requiredEntities:
            - name: "Account"
              labels:
                - "senderAccountChanges"
                - "receiverAccountChanges"
```

**Field Descriptions**

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

Example schema definition for ERC-20 scenario:

```graphql
type Account @entity {
  id: ID!
  approval: BigInt!
  balance: BigInt!
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

### Example of registering a `loadEntities` function for the `Transfer` event from the above example config:

```rescript
Handlers.ERC20Contract.registerTransferLoadEntities((~event, ~context) => {
  // loading the required accountEntity
  context.account.senderAccountChangesLoad(event.params.from->Ethers.ethAddressToString)
  context.account.receiverAccountChangesLoad(event.params.to->Ethers.ethAddressToString)
})
```

Inspecting the config of the `Transfer` event from the above example config indicates that there is a defined `requiredEntities` field of the following:

```yaml
events:
  - name: "Transfer"
    requiredEntities:
    - name: "Account"
      labels:
        - "senderAccountChanges"
        - "receiverAccountChanges"

```

- The register function `ERC20Contract_registerTransferLoadEntities` follows a naming convention for all events: `register<EventName>LoadEntities`.
- Within the function that is being registered the user must define the criteria for loading the `Account` entity which corresponds to the label defined in the config.
- This is made available to the user through the load entity context defined as `contextUpdator`.
- In the case of the above example the `senderAccountChanges` loads a `Account` entity that corresponds to the `from` received from the event and `receiverAccountChanges` loads a `Account` entity that corresponds to the `to` received from the event.

### Example of registering a `Handler` function for the `Transfer` event and using the loaded entity `senderAccountChanges` and `receiverAccountChanges`:

```rescript
Handlers.ERC20Contract.registerTransferHandler((~event, ~context) => {
  // getting the sender accountEntity
  let senderAccount = context.account.senderAccountChanges()

  switch senderAccount {
  | Some(existingSenderAccount) => {
      // updating accountEntity object
      let accountObject: accountEntity = {
        id: existingSenderAccount.id,
        approval: existingSenderAccount.approval,
        balance: existingSenderAccount.balance->Ethers.BigInt.sub(event.params.value),
      }

      // updating the accountEntity with the new transfer field value
      context.account.update(accountObject)
    }

  | None => {
      // updating accountEntity object
        let accountObject: accountEntity = {
          id: event.params.from->Ethers.ethAddressToString,
          approval: Ethers.BigInt.fromInt(0),
          balance: Ethers.BigInt.fromInt(0) ->Ethers.BigInt.sub(event.params.value),
        }

        // inserting the accountEntity with the new transfer field value
        context.account.insert(accountObject)
    }
  }

  // getting the sender accountEntity
  let receiverAccount = context.account.receiverAccountChanges()

  switch receiverAccount {
  | Some(existingReceiverAccount) => {
      // updating accountEntity object
      let accountObject: accountEntity = {
        id: existingReceiverAccount.id,
        approval: existingReceiverAccount.approval,
        balance: existingReceiverAccount.balance->Ethers.BigInt.add(event.params.value),
      }

      // updating the accountEntity with the new transfer field value
      context.account.update(accountObject)
    }

  | None => {
      // updating accountEntity object
          let accountObject: accountEntity = {
            id: event.params.to->Ethers.ethAddressToString,
            approval: Ethers.BigInt.fromInt(0),
            balance: event.params.value,
          }

          // inserting the accountEntity with the new transfer field value
          context.account.insert(accountObject)
    }
  }
})
```

- The handler functions also follow a naming convention for all events in the form of: `register<EventName>Handler`.
- Once the user has defined their `loadEntities` function, they are then able to retrieve the loaded entity information via the labels Transfer in the `config.yaml` file.
- In the above example, if a `Account` entity is found matching the load criteria in the `loadEntities` function, it will be available via `senderAccountChanges` and `receiverAccountChanges`.
- This is made available to the user through the handler context defined simply as `context`.
- This `context` is the gateway by which the user can interact with the indexer and the underlying database.
- The user can then modify this retrieved entity and subsequently update the `Account` entity in the database.
- This is done via the `context` using the update function (`context.account.update(accountObject)`).
- The user has access to a `accountEntity` type that has all the fields defined in the schema.

This context also provides the following functions per entity that can be used to interact with that entity:

- insert
- update
- delete

---
