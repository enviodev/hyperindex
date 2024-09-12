const { Greeter } = require("generated");

// Handler for the NewGreeting event
Greeter.NewGreeting.handler(async ({ event, context }) => {
  const userId = event.params.user.bits; // The id for the User entity
  const latestGreeting = event.params.greeting.value; // The greeting string that was added
  const currentUserEntity = await context.User.get(userId); // Optional user entity that may already exist

  // Update or create a new User entity
  const userEntity = currentUserEntity
    ? {
        id: userId,
        latestGreeting,
        numberOfGreetings: currentUserEntity.numberOfGreetings + 1,
        greetings: [...currentUserEntity.greetings, latestGreeting],
      }
    : {
        id: userId,
        latestGreeting,
        numberOfGreetings: 1,
        greetings: [latestGreeting],
      };

  context.User.set(userEntity); // Set the User entity in the DB
});

// Handler for the ClearGreeting event
Greeter.ClearGreeting.handler(async ({ event, context }) => {
  const userId = event.params.user.bits; // The id for the User entity
  const currentUserEntity = await context.User.get(userId); // Optional user entity that may already exist

  if (currentUserEntity) {
    context.User.set({
      ...currentUserEntity,
      latestGreeting: "", // Clear the latestGreeting
    });
  }
});
