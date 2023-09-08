let {
  PolygonGreeterContract,
  LineaGreeterContract,
} = require("../generated/src/Handlers.bs.js");

PolygonGreeterContract.NewGreeting.loader((event, context) => {
  context.greeting.greetingWithChangesLoad(event.params.user.toString());
});

PolygonGreeterContract.NewGreeting.handler((event, context) => {
  let user = event.params.user;
  let latestGreeting = event.params.greeting;
  let numberOfGreetings = event.params.numberOfGreetings;

  let existingGreeter = context.greeting.greetingWithChanges;

  if (existingGreeter !== undefined) {
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

PolygonGreeterContract.ClearGreeting.loader((event, context) => {
  context.greeting.greetingWithChangesLoad(event.params.user.toString());
});

PolygonGreeterContract.ClearGreeting.handler((event, context) => {
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

LineaGreeterContract.NewGreeting.loader((event, context) => {
  context.greeting.greetingWithChangesLoad(event.params.user.toString());
});

LineaGreeterContract.NewGreeting.handler((event, context) => {
  let user = event.params.user;
  let latestGreeting = event.params.greeting;
  let numberOfGreetings = event.params.numberOfGreetings;

  let existingGreeter = context.greeting.greetingWithChanges;

  if (existingGreeter !== undefined) {
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

LineaGreeterContract.ClearGreeting.loader((event, context) => {
  context.greeting.greetingWithChangesLoad(event.params.user.toString());
});

LineaGreeterContract.ClearGreeting.handler((event, context) => {
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
