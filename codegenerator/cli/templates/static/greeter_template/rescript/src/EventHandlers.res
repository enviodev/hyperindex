open Types

/**
Registers a loader that loads any values from your database that your
NewGreeting event handler might need on the Greeter contract.
*/
Handlers.GreeterContract.NewGreeting.loader((~event, ~context) => {
  //The id for the "Greeting" entity derived from params of the NewGreeting event
  let userId = event.params.user->Ethers.ethAddressToString
  //Try load in in a "Greeting" entity with id of the user param on the
  //NewGreeting event
  context.greeting.load(userId)
})

/**
Registers a handler that handles any values from the
NewGreeting event on the Greeter contract and index these values into
the DB.
*/
Handlers.GreeterContract.NewGreeting.handler((~event, ~context) => {
  //The id for the "Greeting" entity
  let userId = event.params.user->Ethers.ethAddressToString
  //The greeting string that was added.
  let latestGreeting = event.params.greeting

  //The optional greeting entity that may exist already at "userId"
  //This value would be None in the case that it was not loaded in the
  //loader function above OR in the case where it never existed in the db
  let maybeCurrentGreetingEntity = context.greeting.get(userId)

  //Construct the greetingEntity that is to be set in the DB
  let greetingEntity: greetingEntity = switch maybeCurrentGreetingEntity {
  //In the case there is an existing "Greeting" entity, update its
  //latestGreeting value, increment the numberOfGreetings and append latestGreeting
  //to the array of greetings
  | Some(existingGreetingEntity) => {
      id: userId,
      latestGreeting,
      numberOfGreetings: existingGreetingEntity.numberOfGreetings + 1,
      greetings: existingGreetingEntity.greetings->Belt.Array.concat([latestGreeting]),
    }

  //In the case where there is no Greeting entity at this id. Construct a new one with
  //the current latest greeting, an initial number of greetings as "1" and an initial list
  //of greetings with only the latest greeting.
  | None => {
      id: userId,
      latestGreeting,
      numberOfGreetings: 1,
      greetings: [latestGreeting],
    }
  }

  //Set the greeting entity in the DB with the constructed values
  context.greeting.set(greetingEntity)
})

/**
Registers a loader that loads any values from your database that your
ClearGreeting event handler might need on the Greeter contract.
*/
Handlers.GreeterContract.ClearGreeting.loader((~event, ~context) => {
  //Try load in in a "Greeting" entity with id of the user param on the
  //ClearGreeting event
  context.greeting.load(event.params.user->Ethers.ethAddressToString)
})

/**
Registers a handler that handles any values from the
ClearGreeting event on the Greeter contract and index these values into
the DB.
*/
Handlers.GreeterContract.ClearGreeting.handler((~event, ~context) => {
  //The id for the "Greeting" entity
  let userId = event.params.user->Ethers.ethAddressToString
  //The optional greeting entity that may exist already at "userId"
  //This value would be None in the case that it was not loaded in the
  //loader function above OR in the case where it never existed in the db
  let maybeCurrentGreetingEntity = context.greeting.get(userId)

  switch maybeCurrentGreetingEntity {
  //Only make any changes in the case that there is an existing Greeting
  //Simply clear the latestGreeting by setting it to "" (empty string)
  //and keep all the rest of the data the same
  | Some(existingGreetingEntity) =>
    context.greeting.set({...existingGreetingEntity, latestGreeting: ""})

  | None => ()
  }
})
