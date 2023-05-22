open Types

Handlers.GreeterContract.registerGreetingLoadEntities((~event as _, ~context as _) => {
  ()
})

Handlers.GreeterContract.registerGreetingHandler((~event, ~context) => {
  let greetingObject: greetingEntity = {
    id: event.block.timestamp,
    message: event.params.greeting,    
  }

  context.greeting.insert(greetingObject)
})
