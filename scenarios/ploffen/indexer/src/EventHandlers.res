open Types

/////////////////////////
// EVENT: Create Ploffen
/////////////////////////

Handlers.PloffenContract.CreatePloffen.loader((~event, ~context) => {
  ()
})

Handlers.PloffenContract.CreatePloffen.handler((~event, ~context) => {
  let ploffenObject: ploffengameEntity = {
    id: "MASTER_GAME",
    gameToken: event.params.tokenGameAddress->Address.toString,
    seedAmount: BigInt.fromInt(0),
    gameStartTime: 0,
    status: "Created",
    totalPot: BigInt.fromInt(0),
    users: None,
    winner: None,
    possibleWinner: None,
    possibleGameWinTime: 0,
  }
  context.ploffengame.set(ploffenObject)
})

/////////////////////////
// EVENT: Start Ploffen
/////////////////////////

Handlers.PloffenContract.StartPloffen.loader((~event, ~context) => {
  context.ploffengame.unstartedPloffenLoad("MASTER_GAME")
})

// Why are the event and context not underscored here?
Handlers.PloffenContract.StartPloffen.handler((~event, ~context) => {
  let unstartedPloffen = context.ploffengame.unstartedPloffen()
  switch unstartedPloffen {
  | Some(ploffen) => {
      let ploffenObject: ploffengameEntity = {
        ...ploffen,
        seedAmount: event.params.seedAmount,
        gameStartTime: event.blockTimestamp,
        status: "Started",
        totalPot: event.params.seedAmount,
      }
      context.ploffengame.set(ploffenObject)
    }

  | None => Js.log("trying to start a ploffen that doens't exist")
  }
})

/////////////////////////
// EVENT: Play Ploffen
/////////////////////////

Handlers.PloffenContract.registerPlayPloffenLoadEntities((~event, ~context) => {
  ()
  context.ploffengame.startedPloffenLoad("MASTER_GAME")
  context.user.userLoad(event.params.player->Address.toString)
})

Handlers.PloffenContract.registerPlayPloffenHandler((~event, ~context) => {
  let ploffenMaster = context.ploffengame.startedPloffen()
  let loadedUser = context.user.user()

  switch ploffenMaster {
  | Some(ploffen) =>
    switch loadedUser {
    | Some(user) => {
        let userObject: userEntity = {
          ...user,
          numberOfTimesPlayed: user.numberOfTimesPlayed + 1,
          totalContributed: user.totalContributed->BigInt.add(event.params.amount),
        }
        context.user.set(userObject)

        let ploffenObject: ploffengameEntity = {
          ...ploffen,
          totalPot: ploffen.totalPot->BigInt.add(event.params.amount),
          possibleGameWinTime: event.blockTimestamp + 3600,
          possibleWinner: Some(user.id),
        }
        context.ploffengame.set(ploffenObject)
      }

    | None => {
        let userObject: userEntity = {
          id: event.params.player->Address.toString,
          userAddress: event.params.player->Address.toString,
          numberOfTimesPlayed: 1,
          totalContributed: event.params.amount,
        }
        context.user.set(userObject)

        let ploffenObject: ploffengameEntity = {
          ...ploffen,
          totalPot: ploffen.totalPot->BigInt.add(event.params.amount),
          possibleGameWinTime: event.blockTimestamp + 3600,
          possibleWinner: Some(userObject.id),
          users: Some(Array.append(ploffen.users->Belt.Option.getWithDefault([]), [userObject.id])),
        }
        context.ploffengame.set(ploffenObject)
      }
    }

  | None => Js.log("trying to play a ploffen game that doens't exist")
  }
})

/////////////////////////
// EVENT: Win Ploffen
/////////////////////////

Handlers.PloffenContract.registerWinPloffenLoadEntities((~event, ~context) => {
  context.ploffengame.startedPloffenLoad("MASTER_GAME")
  context.user.userLoad(event.srcAddress)
})

Handlers.PloffenContract.registerWinPloffenHandler((~event, ~context) => {
  let ploffenMaster = context.ploffengame.startedPloffen()

  switch ploffenMaster {
  | Some(ploffen) =>
    let ploffenObject: ploffengameEntity = {
      ...ploffen,
      status: "Ended",
      winner: Some(event.params.winner->Address.toString),
    }
    context.ploffengame.set(ploffenObject)
  | None => Js.log("Trying to win a non-existing ploffen game")
  }
})
