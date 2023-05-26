let { GreeterContract } = require("../generated/src/Handlers.bs.js");

GreeterContract.registerNewGreetingLoadEntities((event, context) => {
  context.greeting.greetingWithChangesLoad(event.params.user.toString());
});

GreeterContract.registerNewGreetingHandler((event, context) => {
  let existingGreeter = context.greeting.greetingWithChangesLoad;

  if (existingGreeter != undefined) {
    context.greeting.update({
      id: event.params.user.toString(),
      latestGreeting: event.params.greeting,
      numberOfGreetings: existingGreeter.numberOfGreetings + 1,
    });
  } else {
    context.greeting.insert({
      id: event.params.user.toString(),
      latestGreeting: event.params.greeting,
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
      id: event.params.user.toString(),
      latestGreeting: "",
      numberOfGreetings: existingGreeter.numberOfGreetings,
    });
  }
});
