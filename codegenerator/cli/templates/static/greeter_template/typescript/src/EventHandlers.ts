import {
  PolygonGreeterContract_NewGreeting_loader,
  PolygonGreeterContract_NewGreeting_handler,
  PolygonGreeterContract_ClearGreeting_loader,
  PolygonGreeterContract_ClearGreeting_handler,
  LineaGreeterContract_NewGreeting_loader,
  LineaGreeterContract_NewGreeting_handler,
  LineaGreeterContract_ClearGreeting_loader,
  LineaGreeterContract_ClearGreeting_handler,
} from "../generated/src/Handlers.gen";

import { greetingEntity } from "../generated/src/Types.gen";

PolygonGreeterContract_NewGreeting_loader(({ event, context }) => {
  context.Greeting.greetingWithChangesLoad(event.params.user.toString());
});

PolygonGreeterContract_NewGreeting_handler(({ event, context }) => {
  let currentGreeter = context.Greeting.greetingWithChanges;

  if (currentGreeter !== undefined) {
    let greetingObject: greetingEntity = {
      id: event.params.user.toString(),
      latestGreeting: event.params.greeting,
      numberOfGreetings: currentGreeter.numberOfGreetings + 1,
      greetings: [...currentGreeter.greetings, event.params.greeting],
    };

    context.Greeting.set(greetingObject);
  } else {
    let greetingObject: greetingEntity = {
      id: event.params.user.toString(),
      latestGreeting: event.params.greeting,
      numberOfGreetings: 1,
      greetings: [event.params.greeting],
    };
    context.Greeting.set(greetingObject);
  }
});

PolygonGreeterContract_ClearGreeting_loader(({ event, context }) => {
  context.Greeting.greetingWithChangesLoad(event.params.user.toString());
});

PolygonGreeterContract_ClearGreeting_handler(({ event, context }) => {
  let currentGreeter = context.Greeting.greetingWithChanges;

  if (currentGreeter !== undefined) {
    let greetingObject: greetingEntity = {
      id: event.params.user.toString(),
      latestGreeting: "",
      numberOfGreetings: currentGreeter.numberOfGreetings,
      greetings: currentGreeter.greetings,
    };

    context.Greeting.set(greetingObject);
  }
});

LineaGreeterContract_NewGreeting_loader(({ event, context }) => {
  context.Greeting.greetingWithChangesLoad(event.params.user.toString());
});

LineaGreeterContract_NewGreeting_handler(({ event, context }) => {
  let currentGreeter = context.Greeting.greetingWithChanges;

  if (currentGreeter !== undefined) {
    let greetingObject: greetingEntity = {
      id: event.params.user.toString(),
      latestGreeting: event.params.greeting,
      numberOfGreetings: currentGreeter.numberOfGreetings + 1,
      greetings: [...currentGreeter.greetings, event.params.greeting],
    };

    context.Greeting.set(greetingObject);
  } else {
    let greetingObject: greetingEntity = {
      id: event.params.user.toString(),
      latestGreeting: event.params.greeting,
      numberOfGreetings: 1,
      greetings: [event.params.greeting],
    };
    context.Greeting.set(greetingObject);
  }
});

LineaGreeterContract_ClearGreeting_loader(({ event, context }) => {
  context.Greeting.greetingWithChangesLoad(event.params.user.toString());
});

LineaGreeterContract_ClearGreeting_handler(({ event, context }) => {
  let currentGreeter = context.Greeting.greetingWithChanges;

  if (currentGreeter !== undefined) {
    let greetingObject: greetingEntity = {
      id: event.params.user.toString(),
      latestGreeting: "",
      numberOfGreetings: currentGreeter.numberOfGreetings,
      greetings: currentGreeter.greetings,
    };

    context.Greeting.set(greetingObject);
  }
});
