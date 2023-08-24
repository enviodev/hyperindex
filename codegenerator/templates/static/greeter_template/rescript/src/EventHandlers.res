open Types

Handlers.GreeterContract.NewGreeting.loader((~event, ~context) => {
  context.greeting.greetingWithChangesLoad(event.params.user->Ethers.ethAddressToString)
})

Handlers.GreeterContract.NewGreeting.handler((~event, ~context) => {
  let currentGreeterOpt = context.greeting.greetingWithChanges

  switch currentGreeterOpt {
  | Some(existingGreeter) => {
      let greetingObject: greetingEntity = {
        id: event.params.user->Ethers.ethAddressToString,
        latestGreeting: event.params.greeting,
        numberOfGreetings: existingGreeter.numberOfGreetings + 1,
        greetings: existingGreeter.greetings->Belt.Array.concat([event.params.greeting]),
      }

      context.greeting.set(greetingObject)
    }

  | None =>
    let greetingObject: greetingEntity = {
      id: event.params.user->Ethers.ethAddressToString,
      latestGreeting: event.params.greeting,
      numberOfGreetings: 1,
      greetings: [event.params.greeting],
    }

    context.greeting.set(greetingObject)
  }
})

Handlers.GreeterContract.ClearGreeting.loader((~event, ~context) => {
  context.greeting.greetingWithChangesLoad(event.params.user->Ethers.ethAddressToString)
  ()
})

Handlers.GreeterContract.ClearGreeting.handler((~event, ~context) => {
  let currentGreeterOpt = context.greeting.greetingWithChanges

  switch currentGreeterOpt {
  | Some(existingGreeter) => {
      let greetingObject: greetingEntity = {
        id: event.params.user->Ethers.ethAddressToString,
        latestGreeting: "",
        numberOfGreetings: existingGreeter.numberOfGreetings,
        greetings: existingGreeter.greetings,
      }

      context.greeting.set(greetingObject)
    }

  | None => ()
  }
})
