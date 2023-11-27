let { GreeterContract } = require("../generated/src/Handlers.bs.js");

GreeterContract.NewGreeting.loader((event, context) => {
  context.Greeting.load(event.params.user);
});

GreeterContract.NewGreeting.handler((event, context) => {
  let user = event.params.user;
  let latestGreeting = event.params.greeting;
  let numberOfGreetings = event.params.numberOfGreetings;

  let existingGreeter = context.Greeting.get(event.params.user);

  if (existingGreeter !== undefined) {
    context.Greeting.set({
      id: user,
      latestGreeting: latestGreeting,
      numberOfGreetings: existingGreeter.numberOfGreetings + 1,
      greetings: [...existingGreeter.greetings, latestGreeting],
    });
  } else {
    context.Greeting.set({
      id: user,
      latestGreeting: latestGreeting,
      numberOfGreetings: 1,
      greetings: [latestGreeting],
    });
  }
});

GreeterContract.ClearGreeting.loader((event, context) => {
  context.Greeting.load(event.params.user);
});

GreeterContract.ClearGreeting.handler((event, context) => {
  let existingGreeter = context.Greeting.get(event.params.user);
  if (existingGreeter !== undefined) {
    context.Greeting.set({
      id: user,
      latestGreeting: "",
      numberOfGreetings: existingGreeter.numberOfGreetings + 1,
      greetings: existingGreeter.greetings,
    });
  }
});
