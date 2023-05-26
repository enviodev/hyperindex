let { GreeterContract } = require("../generated/src/Handlers.bs.js");

GreeterContract.registerNewGreetingLoadEntities((event, context) => {
  context.greeting.greetingWithChangesLoad(event.params.user.toString());
});

GreeterContract.registerNewGreetingHandler((event, context) => {
  let user = event.params.user;
  let latestGreeting = event.params.greeting;
  let numberOfGreetings = event.params.numberOfGreetings;

  let existingGreeter = context.greeting.greetingWithChangesLoad;

  if (existingGreeter != undefined) {
    context.greeting.update({
      id: user.toString(),
      latestGreeting: latestGreeting,
      numberOfGreetings: existingGreeter.numberOfGreetings + 1,
    });
  } else {
    context.greeting.insert({
      id: user.toString(),
      latestGreeting: latestGreeting,
      numberOfGreetings: 1,
    });
  }
});

GreeterContract.registerClearGreetingLoadEntities((event, context) => {
  context.greeting.greetingWithChangesLoad(event.params.user.toString());
});

GreeterContract.registerClearGreetingHandler((event, context) => {
  let existingGreeter = context.greeting.greetingWithChangesLoad;
  if (existingGreeter !== undefined) {
    context.greeting.update({
      id: user.toString(),
      latestGreeting: "",
      numberOfGreetings: existingGreeter.numberOfGreetings + 1,
    });
  }
});
