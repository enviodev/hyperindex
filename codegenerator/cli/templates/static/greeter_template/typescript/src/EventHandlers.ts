import { Greeter, User } from "generated";

// Handler for the NewGreeting event
Greeter.NewGreeting.handler(async ({ event, context }) => {
  const userId = event.params.user;
  const latestGreeting = event.params.greeting;
  const currentUserEntity: User | undefined = await context.User.get(userId);

  // Update or create a new User entity
  const userEntity: User = currentUserEntity
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

  context.User.set(userEntity);
});

// Handler for the ClearGreeting event
Greeter.ClearGreeting.handler(async ({ event, context }) => {
  const userId = event.params.user;
  const currentUserEntity: User | undefined = await context.User.get(userId);

  if (currentUserEntity) {
    // Clear the latestGreeting
    context.User.set({
      ...currentUserEntity,
      latestGreeting: "",
    });
  }
});

