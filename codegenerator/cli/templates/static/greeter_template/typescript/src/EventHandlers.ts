import {
  GreeterContract_NewGreeting_loader,
  GreeterContract_NewGreeting_handler,
  GreeterContract_ClearGreeting_loader,
  GreeterContract_ClearGreeting_handler,
} from "../generated/src/Handlers.gen";

import { GreetingEntity } from "../generated/src/Types.gen";

GreeterContract_NewGreeting_loader(({ event, context }) => {
  context.Greeting.load(event.params.user.toString());
});

GreeterContract_NewGreeting_handler(({ event, context }) => {
  let currentGreeter = context.Greeting.get(event.params.user);

  if (currentGreeter != null) {
    let greetingObject: GreetingEntity = {
      id: event.params.user.toString(),
      latestGreeting: event.params.greeting,
      numberOfGreetings: currentGreeter.numberOfGreetings + 1,
      greetings: [...currentGreeter.greetings, event.params.greeting],
    };

    context.Greeting.set(greetingObject);
  } else {
    let greetingObject: GreetingEntity = {
      id: event.params.user.toString(),
      latestGreeting: event.params.greeting,
      numberOfGreetings: 1,
      greetings: [event.params.greeting],
    };
    context.Greeting.set(greetingObject);
  }
});

GreeterContract_ClearGreeting_loader(({ event, context }) => {
  context.Greeting.load(event.params.user.toString());
});

GreeterContract_ClearGreeting_handler(({ event, context }) => {
  let currentGreeter = context.Greeting.get(event.params.user);

  if (currentGreeter != null) {
    let greetingObject: GreetingEntity = {
      id: event.params.user.toString(),
      latestGreeting: "",
      numberOfGreetings: currentGreeter.numberOfGreetings,
      greetings: currentGreeter.greetings,
    };

    context.Greeting.set(greetingObject);
  }
});
