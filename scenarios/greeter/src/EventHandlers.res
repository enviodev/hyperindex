open Types

Handlers.GreeterContract.registerNewGreetingLoadEntities((~event as _, ~context as _) => {
  ()
})

Handlers.GreeterContract.registerNewGreetingHandler((~event, ~context) => {
  let greetingObject: greetingEntity = {
    id: event.srcAddress,
    latestGreeting: event.params.greeting,  
    numberOfGreetings: 1,
    }

  context.greeting.insert(greetingObject)
})

Handlers.GreeterContract.registerUpdateGreetingLoadEntities((~event as _, ~context as _) => {
  context.greeting.greetingWithChangesLoad(event.srcAddress)
})

Handlers.GreeterContract.registerUpdateGreetingHandler((~event, ~context) => {
   let greetingsCount =
    context.greeting.greetingWithChanges()->Belt.Option.mapWithDefault(1, greeting =>
      greeting.numberOfGreetings + 1
    )

  let greetingObject: greetingEntity = {
    id: event.srcAddress,
    latestGreeting: event.params.greeting,
    numberOfGreetings: updatesCount,    
  }

  context.greeting.update(greetingObject)
})

