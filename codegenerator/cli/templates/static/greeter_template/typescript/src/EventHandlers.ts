import { GreeterContract, UserEntity } from "generated";

/**
Registers a loader that loads any values from your database that your
NewGreeting event handler might need on the Greeter contract.
*/
GreeterContract.NewGreeting.loader(({ event, context }) => {
  //The id for the "User" entity derived from params of the NewGreeting event
  const userId = event.params.user;
  //Try load in in a "User" entity with id of the user param on the
  //NewGreeting event
  context.User.load(userId);
});

/**
Registers a handler that handles any values from the
NewGreeting event on the Greeter contract and index these values into
the DB.
*/
GreeterContract.NewGreeting.handler(({ event, context }) => {
  //The id for the "User" entity
  const userId = event.params.user;
  //The greeting string that was added.
  const latestGreeting = event.params.greeting;

  //The optional User entity that may exist already at "userId"
  //This value would be undefined in the case that it was not loaded in the
  //loader function above OR in the case where it never existed in the db
  const currentUserEntity = context.User.get(userId);

  //Construct the userEntity that is to be set in the DB
  const userEntity: UserEntity = currentUserEntity
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
Registers a loader that loads any values from your database that your
ClearGreeting event handler might need on the Greeter contract.
*/
GreeterContract.ClearGreeting.loader(({ event, context }) => {
  //The id for the "User" entity derived from params of the ClearGreeting event
  const userId = event.params.user;
  //Try load in in a "User" entity with id of the user param on the
  //ClearGreeting event
  context.User.load(userId);
});

/**
Registers a handler that handles any values from the
ClearGreeting event on the Greeter contract and index these values into
the DB.
*/
GreeterContract.ClearGreeting.handler(({ event, context }) => {
  //The id for the "User" entity derived from params of the ClearGreeting event
  const userId = event.params.user;
  //The optional User entity that may exist already at "userId"
  //This value would be "undefined" in the case that it was not loaded in the
  //loader function above OR in the case where it never existed in the db
  const currentUserEntity = context.User.get(userId);

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
