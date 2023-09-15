let {
  PolygonGreeterContract,
  LineaGreeterContract,
} = require("../generated/src/Handlers.bs.js");

PolygonGreeterContract.NewGreeting.loader((event, context) => {
  context.Greeting.greetingWithChangesLoad(event.params.user.toString());
});

PolygonGreeterContract.NewGreeting.handler((event, context) => {
  let user = event.params.user;
  let latestGreeting = event.params.greeting;

  let existingGreeter = context.Greeting.greetingWithChanges;

  if (existingGreeter !== undefined) {
    context.Greeting.set({
      id: user.toString(),
      latestGreeting: latestGreeting,
      numberOfGreetings: existingGreeter.numberOfGreetings + 1,
      greetings: [...existingGreeter.greetings, latestGreeting],
    });
  } else {
    context.Greeting.set({
      id: user.toString(),
      latestGreeting: latestGreeting,
      numberOfGreetings: 1,
      greetings: [latestGreeting],
    });
  }
});

PolygonGreeterContract.ClearGreeting.loader((event, context) => {
  context.Greeting.greetingWithChangesLoad(event.params.user.toString());
});

PolygonGreeterContract.ClearGreeting.handler((event, context) => {
  let existingGreeter = context.Greeting.greetingWithChanges;
  if (existingGreeter !== undefined) {
    context.Greeting.set({
      id: user.toString(),
      latestGreeting: "",
      numberOfGreetings: existingGreeter.numberOfGreetings + 1,
      greetings: existingGreeter.greetings,
    });
  }
});

LineaGreeterContract.NewGreeting.loader((event, context) => {
  context.Greeting.greetingWithChangesLoad(event.params.user.toString());
});

LineaGreeterContract.NewGreeting.handler((event, context) => {
  let user = event.params.user;
  let latestGreeting = event.params.greeting;

  let existingGreeter = context.Greeting.greetingWithChanges;

  if (existingGreeter !== undefined) {
    context.Greeting.set({
      id: user.toString(),
      latestGreeting: latestGreeting,
      numberOfGreetings: existingGreeter.numberOfGreetings + 1,
      greetings: [...existingGreeter.greetings, latestGreeting],
    });
  } else {
    context.Greeting.set({
      id: user.toString(),
      latestGreeting: latestGreeting,
      numberOfGreetings: 1,
      greetings: [latestGreeting],
    });
  }
});

LineaGreeterContract.ClearGreeting.loader((event, context) => {
  context.Greeting.greetingWithChangesLoad(event.params.user.toString());
});

LineaGreeterContract.ClearGreeting.handler((event, context) => {
  let existingGreeter = context.Greeting.greetingWithChanges;
  if (existingGreeter !== undefined) {
    context.Greeting.set({
      id: user.toString(),
      latestGreeting: "",
      numberOfGreetings: existingGreeter.numberOfGreetings + 1,
      greetings: existingGreeter.greetings,
    });
  }
});
