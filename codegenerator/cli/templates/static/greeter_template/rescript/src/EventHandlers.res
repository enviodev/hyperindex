open Types

/**
Registers a handler that handles any values from the
NewGreeting event on the Greeter contract and index these values into
the DB.
*/
Handlers.Greeter.NewGreeting.handler(async ({event, context}) => {
  //The id for the "User" entity
  let userId = event.params.user->Ethers.ethAddressToString
  //The greeting string that was added.
  let latestGreeting = event.params.greeting

  //The optional User entity that may exist already at "userId"
  //This value would be None in the case that it never existed in the db
  let maybeCurrentUserEntity = await context.user.get(userId)

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
Registers a handler that handles any values from the
ClearGreeting event on the Greeter contract and index these values into
the DB.
*/
Handlers.Greeter.ClearGreeting.handler(async ({event, context}) => {
  //The id for the "User" entity
  let userId = event.params.user->Ethers.ethAddressToString
  //The optional User entity that may exist already at "userId"
  //This value would be None in the case that it never existed in the db
  let maybeCurrentUserEntity = await context.user.get(userId)

  switch maybeCurrentUserEntity {
  //Only make any changes in the case that there is an existing User
  //Simply clear the latestGreeting by setting it to "" (empty string)
  //and keep all the rest of the data the same
  | Some(existingUserEntity) =>
    context.user.set({...existingUserEntity, latestGreeting: ""})

  | None => ()
  }
})
