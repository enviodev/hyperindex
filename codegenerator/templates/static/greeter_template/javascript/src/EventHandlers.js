let { GreeterContract } = require("../generated/src/Handlers.bs.js");

GreeterContract.NewGreeting.loader((event, context) => {
  context.greeting.load(event.params.user.toString());
});

GreeterContract.NewGreeting.handler((event, context) => {
  let user = event.params.user;
  let latestGreeting = event.params.greeting;
  let numberOfGreetings = event.params.numberOfGreetings;

  let existingGreeter = context.greeting.greetingWithChanges;

  if (existingGreeter != undefined) {
    context.greeting.set({
      id: user.toString(),
      latestGreeting: latestGreeting,
      numberOfGreetings: existingGreeter.numberOfGreetings + 1,
      greetings: [...existingGreeter.greetings, latestGreeting],
    });
  } else {
    context.greeting.set({
      id: user.toString(),
      latestGreeting: latestGreeting,
      numberOfGreetings: 1,
      greetings: [latestGreeting],
    });
  }
});

GreeterContract.ClearGreeting.loader((event, context) => {
  context.greeting.load(event.params.user.toString());
});

GreeterContract.ClearGreeting.handler((event, context) => {
  let existingGreeter = context.greeting.greetingWithChanges;
  if (existingGreeter !== undefined) {
    context.greeting.set({
      id: user.toString(),
      latestGreeting: "",
      numberOfGreetings: existingGreeter.numberOfGreetings + 1,
      greetings: existingGreeter.greetings,
    });
  }
});
