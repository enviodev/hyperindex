open Types

// Handler for the NewGreeting event
Handlers.Greeter.NewGreeting.handler(async ({event, context}) => {
  let userId = event.params.user->Address.toString // The id for the User entity
  let latestGreeting = event.params.greeting // The greeting string that was added
  let maybeCurrentUserEntity = await context.user.get(userId) // Optional User entity that may already exist

  // Update or create a new User entity
  let userEntity: Entities.User.t = switch maybeCurrentUserEntity {
  | Some(existingUserEntity) => {
      id: userId,
      latestGreeting,
      numberOfGreetings: existingUserEntity.numberOfGreetings + 1,
      greetings: existingUserEntity.greetings->Belt.Array.concat([latestGreeting]),
    }
  | None => {
      id: userId,
      latestGreeting,
      numberOfGreetings: 1,
      greetings: [latestGreeting],
    }
  }

  context.user.set(userEntity) // Set the User entity in the DB
})

// Handler for the ClearGreeting event
Handlers.Greeter.ClearGreeting.handler(async ({event, context}) => {
  let userId = event.params.user->Address.toString // The id for the User entity
  let maybeCurrentUserEntity = await context.user.get(userId) // Optional User entity that may already exist

  switch maybeCurrentUserEntity {
  | Some(existingUserEntity) =>
    context.user.set({...existingUserEntity, latestGreeting: ""}) // Clear the latestGreeting
  | None => ()
  }
})

