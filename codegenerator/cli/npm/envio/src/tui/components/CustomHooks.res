open Belt
module InitApi = {
  type ecosystem = | @as("evm") Evm | @as("fuel") Fuel | @as("svm") Svm
  type body = {
    envioVersion: string,
    envioApiToken: option<string>,
    ecosystem: ecosystem,
    hyperSyncNetworks: array<int>,
    rpcNetworks: array<int>,
  }

  let bodySchema = S.object(s => {
    envioVersion: s.field("envioVersion", S.string),
    envioApiToken: s.field("envioApiToken", S.option(S.string)),
    ecosystem: s.field("ecosystem", S.enum([Evm, Fuel, Svm])),
    hyperSyncNetworks: s.field("hyperSyncNetworks", S.array(S.int)),
    rpcNetworks: s.field("rpcNetworks", S.array(S.int)),
  })

  let makeBody = (~envioVersion, ~envioApiToken, ~config: Config.t) => {
    let hyperSyncNetworks = []
    let rpcNetworks = []
    config.chainMap
    ->ChainMap.values
    ->Array.forEach(({sourceConfig, id}) => {
      // Check if chain uses HyperSync based on sourceConfig
      let usesHyperSync = switch sourceConfig {
      | Config.EvmSourceConfig({hypersync: Some(_)}) => true
      | Config.EvmSourceConfig({hypersync: None}) => false
      | Config.FuelSourceConfig(_) => true // Fuel always uses HyperFuel
      | Config.SvmSourceConfig(_) => false
      }
      switch usesHyperSync {
      | true => hyperSyncNetworks
      | false => rpcNetworks
      }
      ->Js.Array2.push(id)
      ->ignore
    })

    {
      envioVersion,
      envioApiToken,
      ecosystem: (config.ecosystem.name :> ecosystem),
      hyperSyncNetworks,
      rpcNetworks,
    }
  }

  type messageColor =
    | @as("primary") Primary
    | @as("secondary") Secondary
    | @as("info") Info
    | @as("danger") Danger
    | @as("success") Success
    | @as("white") White
    | @as("gray") Gray

  let toTheme = (color: messageColor): Style.chalkTheme =>
    switch color {
    | Primary => Primary
    | Secondary => Secondary
    | Info => Info
    | Danger => Danger
    | Success => Success
    | White => White
    | Gray => Gray
    }

  type message = {
    color: messageColor,
    content: string,
  }

  let messageSchema = S.object(s => {
    color: s.field("color", S.enum([Primary, Secondary, Info, Danger, Success, White, Gray])),
    content: s.field("content", S.string),
  })

  let client = Rest.client(Env.envioAppUrl ++ "/api")

  let route = Rest.route(() => {
    method: Post,
    path: "/hyperindex/init",
    input: s => s.body(bodySchema),
    responses: [s => s.field("messages", S.array(messageSchema))],
  })

  let getMessages = async (~config) => {
    let envioVersion = Utils.EnvioPackage.value.version
    let body = makeBody(~envioVersion, ~envioApiToken=Env.envioApiToken, ~config)

    switch await route->Rest.fetch(body, ~client) {
    | exception exn => Error(exn->Obj.magic)
    | messages => Ok(messages)
    }
  }
}

type request<'ok, 'err> = Data('ok) | Loading | Err('err)

let useMessages = (~config) => {
  let (request, setRequest) = React.useState(_ => Loading)
  React.useEffect0(() => {
    InitApi.getMessages(~config)
    ->Promise.thenResolve(res =>
      switch res {
      | Ok(data) => setRequest(_ => Data(data))
      | Error(e) =>
        Logging.error({
          "msg": "Failed to load messages from envio server",
          "err": e->Utils.prettifyExn,
        })
        setRequest(_ => Err(e))
      }
    )
    ->ignore
    None
  })
  request
}
