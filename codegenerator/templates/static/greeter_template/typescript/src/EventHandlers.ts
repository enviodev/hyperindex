import {
  GreeterContract_NewGreeting_loader,
  GreeterContract_NewGreeting_handler,
  GreeterContract_ClearGreeting_loader,
  GreeterContract_ClearGreeting_handler,
} from "../generated/src/Handlers.gen";

import { greetingEntity } from "../generated/src/Types.gen";

GreeterContract_NewGreeting_loader(({ event, context }) => {
  context.greeting.greetingWithChangesLoad(event.params.user.toString());
});

GreeterContract_NewGreeting_handler(({ event, context }) => {
  let currentGreeter = context.greeting.greetingWithChanges();

  if (currentGreeter != null) {
    let greetingObject: greetingEntity = {
      id: event.params.user.toString(),
      latestGreeting: event.params.greeting,
      numberOfGreetings: currentGreeter.numberOfGreetings + 1,
      greetings: [...currentGreeter.greetings, event.params.greeting],
    };

    context.greeting.set(greetingObject);
  } else {
    let greetingObject: greetingEntity = {
      id: event.params.user.toString(),
      latestGreeting: event.params.greeting,
      numberOfGreetings: 1,
      greetings: [event.params.greeting],
    };
    context.greeting.set(greetingObject);
  }
});

GreeterContract_ClearGreeting_loader(({ event, context }) => {
  context.greeting.greetingWithChangesLoad(event.params.user.toString());
});

GreeterContract_ClearGreeting_handler(({ event, context }) => {
  let currentGreeter = context.greeting.greetingWithChanges();

  if (currentGreeter != null) {
    let greetingObject: greetingEntity = {
      id: event.params.user.toString(),
      latestGreeting: "",
      numberOfGreetings: currentGreeter.numberOfGreetings,
      greetings: currentGreeter.greetings,
    };

    context.greeting.set(greetingObject);
  }
});
