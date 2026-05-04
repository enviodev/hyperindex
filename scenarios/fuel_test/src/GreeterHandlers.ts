import { indexer, type User } from "envio";

// Type-level regression guards for `where.block` on Fuel. Declared as an
// unreached function so `tsc --noEmit` checks the types without runtime
// re-registering events. The `@ts-expect-error` assertions catch the
// class of bug where `FuelOnEventWhere` was previously aliased to
// `EvmOnEventWhere`, bypassing `FuelOnEventWhereFilter` and typing Fuel
// users against EVM's `block.number` shape — a silent runtime no-op.
// eslint-disable-next-line @typescript-eslint/no-unused-vars
function _typeCheckFuelWhereBlockShape() {
  indexer.onEvent(
    {
      contract: "Greeter",
      event: "NewGreeting",
      where: { block: { height: { _gte: 1 } } },
    },
    async () => {},
  );
  indexer.onEvent(
    {
      contract: "Greeter",
      event: "NewGreeting",
      where: {
        block: {
          // @ts-expect-error Fuel keys block by `height`, not `number`.
          number: { _gte: 1 },
        },
      },
    },
    async () => {},
  );
  indexer.onEvent(
    {
      contract: "Greeter",
      event: "NewGreeting",
      where: {
        block: {
          height: {
            // @ts-expect-error Only `_gte` is supported on event filters.
            _lte: 1,
          },
        },
      },
    },
    async () => {},
  );
}

/**
Registers a handler that handles any values from the
NewGreeting event on the Greeter contract and index these values into
the DB.
*/
indexer.onEvent({ contract: "Greeter", event: "NewGreeting" }, async ({ event, context }) => {
  //The id for the "User" entity
  const userId = event.params.user.bits;
  //The greeting string that was added.
  const latestGreeting = event.params.greeting.value;

  //The optional User entity that may exist already at "userId"
  //This value would be undefined in the case that it was not loaded in the
  //loader function above OR in the case where it never existed in the db
  const currentUserEntity = await context.User.get(userId);

  //Construct the userEntity that is to be set in the DB
  const userEntity: User = currentUserEntity
    ? //In the case there is an existing "User" entity, update its
      //latestGreeting value, increment the numberOfGreetings and append latestGreeting
      //to the array of greetings
      {
        id: userId,
        latestGreeting,
        numberOfGreetings: currentUserEntity.numberOfGreetings + 1,
        greetings: [...currentUserEntity.greetings, latestGreeting],
      }
    : //In the case where there is no User entity at this id. Construct a new one with
      //the current latest greeting, an initial number of greetings as "1" and an initial list
      //of greetings with only the latest greeting.
      {
        id: userId,
        latestGreeting,
        numberOfGreetings: 1,
        greetings: [latestGreeting],
      };

  //Set the User entity in the DB with the constructed values
  context.User.set(userEntity);
});

/**
Registers a handler that handles any values from the
ClearGreeting event on the Greeter contract and index these values into
the DB.
*/
indexer.onEvent({ contract: "Greeter", event: "ClearGreeting" }, async ({ event, context }) => {
  //The id for the "User" entity derived from params of the ClearGreeting event
  const userId = event.params.user.bits;
  //The optional User entity that may exist already at "userId"
  //This value would be "undefined" in the case that it was not loaded in the
  //loader function above OR in the case where it never existed in the db
  const currentUserEntity = await context.User.get(userId);

  if (currentUserEntity) {
    //Only make any changes in the case that there is an existing User
    //Simply clear the latestGreeting by setting it to "" (empty string)
    //and keep all the rest of the data the same
    context.User.set({
      ...currentUserEntity,
      latestGreeting: "",
    });
  }
});
