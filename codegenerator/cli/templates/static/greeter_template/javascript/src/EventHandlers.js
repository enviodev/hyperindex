let { GreeterContract } = require("../generated/src/Handlers.bs.js");

/**
Registers a loader that loads any values from your database that your
NewGreeting event handler might need on the Greeter contract.
*/
GreeterContract.NewGreeting.loader((event, context) => {
  //The id for the "Greeting" entity derived from params of the NewGreeting event
  const userId = event.params.user;
  //Try load in in a "Greeting" entity with id of the user param on the
  //NewGreeting event
  context.Greeting.load(userId);
});

/**
Registers a handler that handles any values from the
NewGreeting event on the Greeter contract and index these values into
the DB.
*/
GreeterContract.NewGreeting.handler((event, context) => {
  //The id for the "Greeting" entity
  const userId = event.params.user;
  //The greeting string that was added.
  const latestGreeting = event.params.greeting;

  //The optional greeting entity that may exist already at "userId"
  //This value would be undefined in the case that it was not loaded in the
  //loader function above OR in the case where it never existed in the db
  const currentGreetingEntity = context.Greeting.get(userId);

  //Construct the greetingEntity that is to be set in the DB
  const greetingEntity = currentGreetingEntity
    ? //In the case there is an existing "Greeting" entity, update its
    //latestGreeting value, increment the numberOfGreetings and append latestGreeting
    //to the array of greetings
    {
      id: userId,
      latestGreeting,
      numberOfGreetings: currentGreetingEntity.numberOfGreetings + 1,
      greetings: [...currentGreetingEntity.greetings, latestGreeting],
    }
    : //In the case where there is no Greeting entity at this id. Construct a new one with
    //the current latest greeting, an initial number of greetings as "1" and an initial list
    //of greetings with only the latest greeting.
    {
      id: userId,
      latestGreeting,
      numberOfGreetings: 1,
      greetings: [latestGreeting],
    };

  //Set the greeting entity in the DB with the constructed values
  context.Greeting.set(greetingEntity);
});

/**
Registers a loader that loads any values from your database that your
ClearGreeting event handler might need on the Greeter contract.
*/
GreeterContract.ClearGreeting.loader((event, context) => {
  //The id for the "Greeting" entity derived from params of the ClearGreeting event
  const userId = event.params.user;
  //Try load in in a "Greeting" entity with id of the user param on the
  //ClearGreeting event
  context.Greeting.load(userId);
});

/**
Registers a handler that handles any values from the
ClearGreeting event on the Greeter contract and index these values into
the DB.
*/
GreeterContract.ClearGreeting.handler((event, context) => {
  //The id for the "Greeting" entity derived from params of the ClearGreeting event
  const userId = event.params.user;
  //The optional greeting entity that may exist already at "userId"
  //This value would be "undefined" in the case that it was not loaded in the
  //loader function above OR in the case where it never existed in the db
  const currentGreetingEntity = context.Greeting.get(userId);

  if (currentGreetingEntity) {
    //Only make any changes in the case that there is an existing Greeting
    //Simply clear the latestGreeting by setting it to "" (empty string)
    //and keep all the rest of the data the same
    context.Greeting.set({
      ...currentGreetingEntity,
      latestGreeting: "",
    });
  }
});
