// The contractRegister handler context: context.chain.ContractName.add(address).
// Independent of the in-memory store, so it stays off IndexerState and the
// fetch-time contract registration in ChainState doesn't pull the state in.

// One context for every contract register run of an indexer. Each run is told
// apart by the RunScope it's entered with, so `add` reaches the run's own item
// and registrations even when kept and called later, and is refused once the
// run resolved.
let make = (~config: Config.t): Internal.contractRegisterContext => {
  let chain = Utils.StrictObject.make(
    Utils.StrictObject.makePrototype(prop =>
      JsError.throwWithMessage(
        `Invalid contract name '${prop}' on context.chain. ${EntityFilter.codegenHelpMessage}`,
      )
    ),
  )
  chain
  ->Utils.Object.defineProperty(
    "id",
    {
      enumerable: true,
      get: () =>
        RunScope.currentContractRegisterRunOrThrow(~prop="chain").item->Internal.getItemChainId,
    },
  )
  ->ignore
  // A contract configured on several chains is one property.
  let contractNames = Utils.Set.make()
  config.chainMap
  ->ChainMap.values
  ->Array.forEach(chainConfig =>
    chainConfig.contracts->Array.forEach(({name}) => contractNames->Utils.Set.add(name)->ignore)
  )
  contractNames->Utils.Set.forEach(contractName =>
    chain
    ->Utils.Object.definePropertyWithValue(
      contractName,
      {
        enumerable: true,
        value: {
          "add": (contractAddress: Address.t) => {
            let run = RunScope.currentContractRegisterRunOrThrow(~prop="chain")
            run.registrations
            ->Array.push({
              // The value is passed from user-land, so validate and checksum/lowercase it.
              address: config->Config.normalizeUserAddress(contractAddress),
              contractName,
              registrationBlock: run.item->Internal.getItemBlockNumber,
              creationRound: ?run.creationRound,
            })
            ->ignore
          },
        },
      },
    )
    ->ignore
  )

  let context = Utils.StrictObject.make(
    Utils.StrictObject.makePrototype(prop =>
      JsError.throwWithMessage(
        `Invalid context access by '${prop}' property. Use context.chain.ContractName.add(address) to register contracts. ${EntityFilter.codegenHelpMessage}`,
      )
    ),
  )
  context
  ->Utils.Object.defineProperty(
    "log",
    {
      enumerable: true,
      get: () =>
        RunScope.currentContractRegisterRunOrThrow(~prop="log")
        ->RunScope.contractRegisterLogger
        ->Logger.asContextLog,
    },
  )
  ->ignore
  context
  ->Utils.Object.defineProperty(
    "chain",
    {
      enumerable: true,
      get: () => {
        let _ = RunScope.currentContractRegisterRunOrThrow(~prop="chain")
        chain
      },
    },
  )
  ->ignore
  context
}
