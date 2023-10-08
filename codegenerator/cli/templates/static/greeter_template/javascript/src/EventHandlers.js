let {
  PolygonGreeterContract,
  LineaGreeterContract,
} = require("../generated/src/Handlers.bs.js");

PolygonGreeterContract.NewGreeting.loader((event, context) => {
  context.Greeting.load(event.params.user);
});

PolygonGreeterContract.NewGreeting.handler((event, context) => {
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

PolygonGreeterContract.ClearGreeting.loader((event, context) => {
  context.Greeting.load(event.params.user);
});

PolygonGreeterContract.ClearGreeting.handler((event, context) => {
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

LineaGreeterContract.NewGreeting.loader((event, context) => {
  context.Greeting.load(event.params.user);
});

LineaGreeterContract.NewGreeting.handler((event, context) => {
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

LineaGreeterContract.ClearGreeting.loader((event, context) => {
  context.Greeting.load(event.params.user);
});

LineaGreeterContract.ClearGreeting.handler((event, context) => {
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
