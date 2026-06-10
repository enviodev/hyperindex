type cfg = {url: string}

type t = {getHeight: unit => promise<int>}

@send
external classNew: (Core.rpcClientCtor, cfg) => t = "new"

let make = (~url) => Core.getAddon().rpcClient->classNew({url: url})
