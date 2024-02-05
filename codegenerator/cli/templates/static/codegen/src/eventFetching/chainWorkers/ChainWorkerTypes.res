type chainId = int
exception UndefinedChainConfig(chainId)
exception IncorrectSyncSource(Config.syncSource)

type chainWorker = Config.source<HyperSyncWorker.t, RpcWorker.t>
