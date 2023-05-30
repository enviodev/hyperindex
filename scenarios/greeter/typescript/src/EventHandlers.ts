import {
  GreeterContract_registerNewGreetingLoadEntities,
  GreeterContract_registerNewGreetingHandler,
  GreeterContract_registerClearGreetingLoadEntities,
  GreeterContract_registerClearGreetingHandler,
} from "../generated/src/Handlers.gen";

import { greetingEntity } from "../generated/src/Types.gen";

GreeterContract_registerNewGreetingLoadEntities(({ event, context }) => {
  context.greeting.greetingWithChangesLoad(event.params.user.toString());
});

GreeterContract_registerNewGreetingHandler(({ event, context }) => {
  let currentGreeter = context.greeting.greetingWithChanges();

  if (currentGreeter != null) {
    let greetingObject: greetingEntity = {
      id: event.params.user.toString(),
      latestGreeting: event.params.greeting,
      numberOfGreetings: currentGreeter.numberOfGreetings + 1,
    };

    context.greeting.update(greetingObject);
  } else {
    let greetingObject: greetingEntity = {
      id: event.params.user.toString(),
      latestGreeting: event.params.greeting,
      numberOfGreetings: 1,
    };
    context.greeting.insert(greetingObject);
  }
});

GreeterContract_registerClearGreetingLoadEntities(({ event, context }) => {
  context.greeting.greetingWithChangesLoad(event.params.user.toString());
});

GreeterContract_registerClearGreetingHandler(({ event, context }) => {
  let currentGreeter = context.greeting.greetingWithChanges();

  if (currentGreeter != null) {
    let greetingObject: greetingEntity = {
      id: event.params.user.toString(),
      latestGreeting: "",
      numberOfGreetings: currentGreeter.numberOfGreetings,
    };

    context.greeting.update(greetingObject);
  } else {
  }
});
