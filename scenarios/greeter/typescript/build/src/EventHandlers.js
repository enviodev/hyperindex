"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const Handlers_gen_1 = require("../generated/src/Handlers.gen");
(0, Handlers_gen_1.GreeterContract_registerNewGreetingLoadEntities)(({ event, context }) => {
    context.greeting.greetingWithChangesLoad(event.params.user.toString());
});
(0, Handlers_gen_1.GreeterContract_registerNewGreetingHandler)(({ event, context }) => {
    let currentGreeter = context.greeting.greetingWithChanges();
    if (currentGreeter != null) {
        let greetingObject = {
            id: event.params.user.toString(),
            latestGreeting: event.params.greeting,
            numberOfGreetings: currentGreeter.numberOfGreetings + 1,
        };
        context.greeting.update(greetingObject);
    }
    else {
        let greetingObject = {
            id: event.params.user.toString(),
            latestGreeting: event.params.greeting,
            numberOfGreetings: 1,
        };
        context.greeting.insert(greetingObject);
    }
});
(0, Handlers_gen_1.GreeterContract_registerClearGreetingLoadEntities)(({ event, context }) => {
    context.greeting.greetingWithChangesLoad(event.params.user.toString());
});
(0, Handlers_gen_1.GreeterContract_registerClearGreetingHandler)(({ event, context }) => {
    let currentGreeter = context.greeting.greetingWithChanges();
    if (currentGreeter != null) {
        let greetingObject = {
            id: event.params.user.toString(),
            latestGreeting: "",
            numberOfGreetings: currentGreeter.numberOfGreetings,
        };
        context.greeting.update(greetingObject);
    }
    else {
    }
});
