open Types

/**
Registers a loader that loads any values from your database that your
NewGreeting event handler might need on the Greeter contract.
*/
Handlers.GreeterContract.NewGreeting.loader(({event, context}) => {
  //The id for the "User" entity derived from params of the NewGreeting event
  let userId = event.data.user.value
  //Try load in in a "User" entity with id of the user param on the
  //NewGreeting event
  context.user.load(userId)
})

/**
Registers a handler that handles any values from the
NewGreeting event on the Greeter contract and index these values into
the DB.
*/
Handlers.GreeterContract.NewGreeting.handler(({event, context}) => {
  //The id for the "User" entity
  let userId = event.data.user.value
  //The greeting string that was added.
  let latestGreeting = event.data.greeting.value

  //The optional User entity that may exist already at "userId"
  //This value would be None in the case that it was not loaded in the
  //loader function above OR in the case where it never existed in the db
  let maybeCurrentUserEntity = context.user.get(userId)

  //Construct the userEntity that is to be set in the DB
  let userEntity: userEntity = switch maybeCurrentUserEntity {
  //In the case there is an existing "User" entity, update its
  //latestGreeting value, increment the numberOfGreetings and append latestGreeting
  //to the array of greetings
  | Some(existingUserEntity) => {
      id: userId,
      latestGreeting,
      numberOfGreetings: existingUserEntity.numberOfGreetings + 1,
      greetings: existingUserEntity.greetings->Belt.Array.concat([latestGreeting]),
    }

  //In the case where there is no User entity at this id. Construct a new one with
  //the current latest greeting, an initial number of greetings as "1" and an initial list
  //of greetings with only the latest greeting.
  | None => {
      id: userId,
      latestGreeting,
      numberOfGreetings: 1,
      greetings: [latestGreeting],
    }
  }

  //Set the User entity in the DB with the constructed values
  context.user.set(userEntity)
})

/**
Registers a loader that loads any values from your database that your
ClearGreeting event handler might need on the Greeter contract.
*/
Handlers.GreeterContract.ClearGreeting.loader(({event, context}) => {
  //Try load in in a "User" entity with id of the user param on the
  //ClearGreeting event
  context.user.load(event.data.user.value)
})

/**
Registers a handler that handles any values from the
ClearGreeting event on the Greeter contract and index these values into
the DB.
*/
Handlers.GreeterContract.ClearGreeting.handler(({event, context}) => {
  //The id for the "User" entity
  let userId = event.data.user.value
  //The optional User entity that may exist already at "userId"
  //This value would be None in the case that it was not loaded in the
  //loader function above OR in the case where it never existed in the db
  let maybeCurrentUserEntity = context.user.get(userId)

  switch maybeCurrentUserEntity {
  //Only make any changes in the case that there is an existing User
  //Simply clear the latestGreeting by setting it to "" (empty string)
  //and keep all the rest of the data the same
  | Some(existingUserEntity) => context.user.set({...existingUserEntity, latestGreeting: ""})
  | None => ()
  }
})
