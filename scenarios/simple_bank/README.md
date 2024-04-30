# SimpleBank contract

SimpleBank is a smart contract that allows users to deposit and withdraw funds, with following features:

- Keeps track of user's balance as well as total balance over time.
- User balance accrues interest over time according to the interest rate that is set on the contract.
- Emits events every time a deposit or withdrawal is made.

## Indexer Requirements

The following files are required to use the Indexer:

- Configuration (defaults to `config.yaml`)
- GraphQL Schema (defaults to `schema.graphql`)
- Event Handlers (defaults to `src/EventHandlers.*` depending on language chosen)

These files are auto-generated according to a template by running `envio init` command.

## Configuration Setup

Sample from config file from SimpleBank scenario:

```yaml
name: Simple bank
description: Simple Bank contract
networks:
  - id: 1337
    rpc_config:
      url: http://localhost:8545
    start_block: 0
    contracts:
      - name: SimpleBank
        abi_file_path: contracts/abis/SimpleBank.json
        address: ["0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"]
        handler: src/EventHandlers.js
        events:
          - name: "AccountCreated"
            requiredEntities: [] # empty signifies no requirements
          - name: "DepositMade"
            requiredEntities:
              - name: "Account"
                labels:
                  - "accountBalanceChanges"
```

**Field Descriptions**

- `version` - Version of the indexer
- `description` - Description of the project
- `networks` - Configuration of the blockchain networks that the project is deployed on
  - `id` - Chain identifier of the network
- `rpc_config` - RPC Config that will be used to subscribe to blockchain data on this network
  - `url` - URL of the RPC endpoint
  - `start_block` - Initial block from which the indexer will start listening for events
  - `contracts` - Configuration for each contract deployed on the network
    - `name` - User defined contract name
    - `abi_file_path` - File location of the contract abi
    - `address` - An array of addresses that the contract is deployed to on the network
    - `handler` - Location of the file that handles the events emitted by this contract
    - `events` - Configuration for each event emitted by this contract that the indexer will listen for
      - `name` - Name of the event (must match the name in the abi)
      - `required_entities` - An array of entities that need to loaded and made accessible within the handler function (an empty array indicates that no entities are required)
        - `name` - The name of the required entity (must match an entity defined in the schema)
        - `label` - A user defined label that corresponds to this entity load

## GraphQL Schema definition

The `schema.graphql` file contains the definitions of all user-defined entities. These entity types are then created/modified within the handler files.

Example schema definition for Simple scenario:

```graphql
type Account @entity {
  id: ID!
  address: Bytes!
  balance: Float!
  depositCount: Int!
  withdrawalCount: Int!
}
```

## Writing Event Handlers

Once the configuration and graphQL schema files are in place, run
`envio codegen` in the project directory.

The entity and event types will then be available in the handler files.

A user can specify a specific handler file per contract that processes events emitted by that contract.
Each event handler requires two functions to be registered in order to enable full functionality within the indexer.

1. An `<event>LoadEntities` function
2. An `<event>Handler` function

### Example of registering a `loadEntities` function for the `DepositMade` event from the above example config in TypeScript:

```typescript
SimpleBankContract_registerDepositMadeLoadEntities(({ event, context }) => {
  context.account.accountBalanceChangesLoad(
    event.params.userAddress.toString()
  );
});
```

Inspecting the config of the `DepositMade` event from the above example config indicates that there is a defined `requiredEntities` field of the following:

```yaml
events:
  - name: "DepositMade"
    requiredEntities:
      - name: "Account"
        labels:
          - "accountBalanceChanges"
```

The register function `registerDepositMadeLoadEntities` follows a naming convention for all events: `register<EventName>LoadEntities`.

Within the function that is being registered the user must define the criteria for loading the `accountBalanceChanges` entity which corresponds to the label defined in the config. This is made available to the user through the load entity context defined as `contextUpdator`.

In the case of the above example the `accountBalanceChanges` loads a `Account` entity that corresponds to the id received from the event.

### Example of registering a `Handler` function for the `DepositMade` event and using the loaded entity `accountBalanceChanges`:

```typescript
SimpleBankContract_registerDepositMadeHandler(({ event, context }) => {
  let { userAddress, amount } = event.params;

  let previousAccountBalance =
    context.account.accountBalanceChanges()?.balance ?? 0;
  let nextAccountBalance = Number(previousAccountBalance) + Number(amount);

  let previousAccountDepositCount =
    context.account.accountBalanceChanges()?.depositCount ?? 0;
  let nextAccountDepositCount = previousAccountDepositCount + 1;

  let previousAccountWithdrawalCount =
    context.account.accountBalanceChanges()?.withdrawalCount ?? 0;

  let account: accountEntity = {
    id: userAddress.toString(),
    address: userAddress.toString(),
    balance: nextAccountBalance,
    depositCount: nextAccountDepositCount,
    withdrawalCount: previousAccountWithdrawalCount,
  };

  context.account.update(account);
});
```

The handler functions also follow a naming convention for all events in the form of: `register<EventName>Handler`.
Once the user has defined their `loadEntities` function they are then able to retrieve the loaded entity information via the labels defined in the `config.yaml` file.
In the above example, if a `Account` entity is found matching the load criteria in the `loadEntities` function, it will be available via `accountBalanceChanges`. This is made available to the user through the handler context defined simply as `context`. This context is the gateway by which the user can interact with the indexer and the underlying database.
The user can then modify this retrieved entity and subsequently update the `Account` entity in the database. This is done via the context using the update function (`context.account.update(account)`).
The user has access to a `Account` type that has all the fields defined in the schema.

This context also provides the following functions per entity that can be used to interact with that entity:

- insert
- update
- delete

## Code generation and running the scenario

Once the user has defined the above config and handler files, the following can be used to run the indexer on the scenario

Run from this directory:

```bash
pnpm all
```

This command will stop and start the docker images and re-generate all the files required for indexing.

## Running tasks

To run tasks for sample users, run the following

```bash
pnpm test-user-1
pnpm test-user-2
```

This will create sample users 1 and 2 to perform several deposit and withdraw actions.

## Viewing the results

To view the data in the database, run

```bash
pnpm view-results
```

Admin-secret for Hasura is `testing`

Alternatively you can open the file `index.html` for a cleaner experience (no Hasura stuff). Unfortunately, Hasura is currently not configured to make the data public.
