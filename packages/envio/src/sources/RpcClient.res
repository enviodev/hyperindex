type cfg = {url: string}

type t = {getHeight: unit => promise<int>}

@send
external classNew: (Core.evmRpcClientCtor, cfg) => t = "new"

let make = (~url) => Core.getAddon().evmRpcClient->classNew({url: url})
