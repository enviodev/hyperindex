module InitApi = {
  type body = {
    @as("version") envioVersion: string,
    @as("apiToken") hasApiToken: bool,
    usesHyperSync: bool,
    config: ConfigYAML.t,
  }

  let makeBody = (~envioVersion, ~hasApiToken, ~config: ConfigYAML.t) => {
    let usesHyperSync =
      config.chains
      ->Js.Dict.values
      ->Belt.Array.reduce(false, (accum, item) => {accum || item.syncSource->Config.usesHyperSync})
    {
      envioVersion,
      hasApiToken,
      usesHyperSync,
      config,
    }
  }

  let bodySchema = S.object(s => {
    envioVersion: s.field("version", S.string),
    hasApiToken: s.fieldOr("apiToken", S.bool, false),
    usesHyperSync: s.field("usesHyperSync", S.bool),
    config: s.field("config", ConfigYAML.schema),
  })

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
      PersistedState.getPersistedState()->Belt.Result.mapWithDefault("unknown", ps =>
        ps.envioVersion
      )
    let hasApiToken = Env.envioApiToken->Belt.Option.isSome
    let body = makeBody(~envioVersion, ~hasApiToken, ~config)
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
      | Error(e) => setRequest(_ => Err(e))
      }
    )
    ->ignore
    None
  })
  request
}
