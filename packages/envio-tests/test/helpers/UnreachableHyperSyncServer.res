// A HyperSync address that drops every connection attempt, like a node
// blackholed on the client's network (Linux only).
type t

@send external classNew: Core.unreachableHyperSyncServerCtor => t = "new"
@send external url: t => string = "url"

let make = () => Core.getAddon().unreachableHyperSyncServer->classNew
