open Belt
module InitApi = {
  type ecosystem = | @as("evm") Evm | @as("fuel") Fuel
  type body = {
    envioVersion: option<string>,
    envioApiToken: option<string>,
    ecosystem: ecosystem,
    hyperSyncNetworks: array<int>,
    rpcNetworks: array<int>,
  }

  let bodySchema = S.object(s => {
    envioVersion: s.field("envioVersion", S.option(S.string)),
    envioApiToken: s.field("envioApiToken", S.option(S.string)),
    ecosystem: s.field("ecosystem", Utils.Schema.enum([Evm, Fuel])),
    hyperSyncNetworks: s.field("hyperSyncNetworks", S.array(S.int)),
    rpcNetworks: s.field("rpcNetworks", S.array(S.int)),
  })

  let makeBody = (~envioVersion, ~envioApiToken, ~config: Config.t) => {
    let ecosystem = ref(Evm)
    let hyperSyncNetworks = []
    let rpcNetworks = []
    config.chainMap
    ->ChainMap.values
    ->Array.forEach(({syncSource, chain}) => {
      switch syncSource {
      | HyperSync(_) => hyperSyncNetworks
      | HyperFuel(_) =>
        ecosystem := Fuel
        hyperSyncNetworks
      | Rpc(_) => rpcNetworks
      }
      ->Js.Array2.push(chain->ChainMap.Chain.toChainId)
      ->ignore
    })

    {
      envioVersion,
      envioApiToken,
      ecosystem: ecosystem.contents,
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
    color: s.field("color", Utils.Schema.enum([Primary, Secondary, Info, Danger, Success, White, Gray])),
    content: s.field("content", S.string),
  })

  let endpoint = Env.envioApiUrl ++ "/hyperindex/init"

  let route = Rest.route(() => {
    method: Post,
    path: "/hyperindex/init",
    variables: s => s.body(bodySchema),
    responses: [s => s.field("messages", S.array(messageSchema))]
  })

  let getMessages = async (~config) => {
    let envioVersion =
      PersistedState.getPersistedState()->Result.mapWithDefault(None, p => Some(p.envioVersion))
    let body = makeBody(~envioVersion, ~envioApiToken=Env.envioApiToken, ~config)

    switch await route->Rest.fetch(endpoint, body) {
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
        Logging.error({"msg": "Failed to load messages from envio server", "err": e})
        setRequest(_ => Err(e))
      }
    )
    ->ignore
    None
  })
  request
}
