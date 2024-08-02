open Belt
module InitApi = {
  type ecosystem = Evm | Fuel
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
    ecosystem: s.field("ecosystem", S.union([S.literal(Evm), S.literal(Fuel)])),
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

  type messageKind = | @as("warning") Warning | @as("destructive") Destructive | @as("info") Info
  type message = {
    kind: messageKind,
    content: string,
  }

  let messageSchema = S.object(s => {
    kind: s.field("kind", S.union([S.literal(Warning), S.literal(Destructive), S.literal(Info)])),
    content: s.field("content", S.string),
  })

  let responseSchema = S.object(s => s.field("messages", S.array(messageSchema)))

  let serverUrl = "https://envio.dev/api"
  let endpoint = serverUrl ++ "/hyperindex/init"

  let getMessages = (~config) => {
    let envioVersion =
      PersistedState.getPersistedState()->Result.mapWithDefault(None, p => Some(p.envioVersion))
    let body = makeBody(~envioVersion, ~envioApiToken=Env.envioApiToken, ~config)
    QueryHelpers.executeFetchRequest(
      ~endpoint,
      ~method=#POST,
      ~bodyAndSchema=(body, bodySchema),
      ~responseSchema,
    )
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
