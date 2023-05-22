open Types

Handlers.GreeterContract.registerNewGreetingLoadEntities((~event as _, ~context as _) => {
  ()
})

Handlers.GreeterContract.registerNewGreetingHandler((~event, ~context) => {
  let greetingObject: greetingEntity = {
    id: event.block.timestamp,
    message: event.params.greeting,    
  }

  context.greeting.insert(greetingObject)
})

Handlers.GreeterContract.registerUpdateGreetingLoadEntities((~event as _, ~context as _) => {
  ()
})

Handlers.GreeterContract.registerUpdateGreetingHandler((~event, ~context) => {
  let greetingObject: greetingEntity = {
    id: event.block.timestamp,
    message: event.params.greeting,    
  }

  context.greeting.insert(greetingObject)
})

Handlers.GreeterContract.registerUpdateGreetingLoadEntities((~event, ~context) => {
  ()
})

Handlers.GreeterContract.registerUpdateGreetingHandler((~event, ~context) => {
  let greetingObject: greetingEntity = {
    id: event.block.timestamp,
    message: event.params.greeting,    
  }

  context.greeting.update(greetingObject)
})

