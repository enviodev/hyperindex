// A chain as its storage holds it: what its `envio_chains` row keeps of its
// config, and the addresses the config declared for it.
type storedChain = {
  id: ChainId.t,
  ecosystem: string,
  startBlock: int,
  endBlock: option<int>,
  maxReorgDepth: int,
  configAddresses: array<AddressRows.row>,
}

// What a storage holds of the config it was built from. `envioInfo` is `None`
// for a storage an older envio built, which kept no such record.
type stored = {
  envioInfo: option<JSON.t>,
  chains: array<storedChain>,
  contractMapping: ContractMapping.t,
}

type t =
  | Resume
  // Configured since the storage was built, and the only chain its
  // `envio start --chain` process drives.
  | AddChain(Config.chain)
  | Incompatible(array<string>)

// The part of a chain's config its storage keeps, shaped so a stored chain and
// a configured one diff by the path config.yaml spells: `chains.137.endBlock`,
// `chains.137.contracts.Token.addresses.0x…`.
let chainEntry = (
  ~startBlock: option<int>,
  ~endBlock: option<int>,
  ~maxReorgDepth: int,
  ~addresses: array<(string, string)>,
) => {
  let contracts = Dict.make()
  addresses->Array.forEach(((contractName, address)) =>
    contracts->Utils.Dict.push(contractName, address)
  )
  let entry = dict{
    "maxReorgDepth": JSON.Number(maxReorgDepth->Int.toFloat),
    "contracts": JSON.Object(
      contracts->Dict.mapValues(addresses => JSON.Object(
        dict{
          "addresses": JSON.Object(
            addresses->Array.map(address => (address, JSON.Boolean(true)))->Dict.fromArray,
          ),
        },
      )),
    ),
  }
  startBlock->Option.forEach(startBlock =>
    entry->Dict.set("startBlock", JSON.Number(startBlock->Int.toFloat))
  )
  endBlock->Option.forEach(endBlock =>
    entry->Dict.set("endBlock", JSON.Number(endBlock->Int.toFloat))
  )
  JSON.Object(entry)
}

let withChains = (envioInfo: JSON.t, ~chains: array<(ChainId.t, JSON.t)>) =>
  switch envioInfo {
  | Object(fields) =>
    let joined = fields->Dict.copy
    joined->Dict.set(
      "chains",
      JSON.Object(
        chains->Array.map(((chainId, entry)) => (chainId->ChainId.toString, entry))->Dict.fromArray,
      ),
    )
    JSON.Object(joined)
  | _ => envioInfo
  }

let olderEnvio = "storage was initialized by an older envio version"

// `envioInfo` is the running config's, `chainConfigs` the chains this process
// drives. An isolated process answers for `envioInfo` and its own chains only:
// the ones it leaves out are checked, and added, by the processes that drive
// them.
let make = (
  ~stored: stored,
  ~envioInfo: JSON.t,
  ~chainConfigs: array<Config.chain>,
  ~contractMapping: ContractMapping.t,
  ~lowercaseAddresses: bool,
  ~isolated: bool,
) =>
  switch stored.envioInfo {
  | None => Incompatible([olderEnvio])
  | Some(storedEnvioInfo) =>
    let storedChainOf = chainId => stored.chains->Array.find(chain => chain.id == chainId)
    let added = switch (isolated, chainConfigs) {
    | (true, [chain]) if storedChainOf(chain.id)->Option.isNone => Some(chain)
    | _ => None
    }
    let storedChains = isolated
      ? stored.chains->Array.filter(storedChain =>
          chainConfigs->Array.some(chain => chain.id == storedChain.id)
        )
      : stored.chains
    let storedEntries = storedChains->Array.map(storedChain => {
      let addresses =
        storedChain.configAddresses
        ->AddressRows.render(~ecosystem=storedChain.ecosystem, ~shouldChecksum=!lowercaseAddresses)
        ->Array.mapWithIndex((address, idx) => (
          stored.contractMapping->ContractMapping.nameOfOrThrow(
            (storedChain.configAddresses->Array.getUnsafe(idx)).contractId,
          ),
          address->Address.toString,
        ))
      (
        storedChain.id,
        chainEntry(
          ~startBlock=Some(storedChain.startBlock),
          ~endBlock=storedChain.endBlock,
          ~maxReorgDepth=storedChain.maxReorgDepth,
          ~addresses,
        ),
      )
    })
    let currentEntries = chainConfigs->Array.filterMap(chain =>
      switch added {
      | Some(added) if added.id == chain.id => None
      | _ =>
        Some((
          chain.id,
          chainEntry(
            // `latest` is whatever it resolved to when the chain was first
            // stored, so it matches any stored block.
            ~startBlock=switch chain.startBlock {
            | Block(startBlock) => Some(startBlock)
            | Latest => storedChainOf(chain.id)->Option.map(storedChain => storedChain.startBlock)
            },
            ~endBlock=chain.endBlock,
            ~maxReorgDepth=chain.maxReorgDepth,
            ~addresses=chain.contracts->Array.flatMap(contract =>
              contract.addresses->Array.map(address => (contract.name, address->Address.toString))
            ),
          ),
        ))
      }
    )
    let changedPaths = Config.diffPaths(
      ~stored=storedEnvioInfo->withChains(~chains=storedEntries),
      ~current=envioInfo->withChains(~chains=currentEntries),
    )
    let changedPaths =
      stored.contractMapping->ContractMapping.isEqual(contractMapping)
        ? changedPaths
        : changedPaths->Array.concat(["contracts"])
    switch (changedPaths, added) {
    | ([], None) => Resume
    | ([], Some(chain)) => AddChain(chain)
    | (changedPaths, _) => Incompatible(changedPaths)
    }
  }

// The configured chains the storage holds nothing of, when adding them is the
// whole of what changed. `changedPaths` names only the first tier that differs,
// so a change in a later tier, an entity say, is caught by planning each new
// chain's own `envio start --chain` run, which checks everything but the chains
// it leaves out.
let newChainIdsWhenOnlyChange = (
  changedPaths: array<string>,
  ~stored: stored,
  ~envioInfo: JSON.t,
  ~chainConfigs: array<Config.chain>,
  ~contractMapping: ContractMapping.t,
  ~lowercaseAddresses: bool,
) => {
  let newChains =
    chainConfigs->Array.filter(chain =>
      !(stored.chains->Array.some(storedChain => storedChain.id == chain.id))
    )
  let isNewChainPath = path =>
    newChains->Array.some(chain => path == `chains.${chain.id->ChainId.toString}`)
  let addsAlone = chain =>
    switch make(
      ~stored,
      ~envioInfo,
      ~chainConfigs=[chain],
      ~contractMapping,
      ~lowercaseAddresses,
      ~isolated=true,
    ) {
    | AddChain(_) => true
    | Resume | Incompatible(_) => false
    }
  changedPaths->Array.every(isNewChainPath) && newChains->Array.every(addsAlone)
    ? newChains->Array.map(chain => chain.id)
    : []
}

let incompatibleMessage = (
  changedPaths,
  ~envioInfo: JSON.t,
  ~resetCommand: string,
  ~runCommand: option<string>,
  ~addChainCommands: array<string>=[],
) => {
  let hasClickhouse = switch envioInfo {
  | Object(d) =>
    switch d->Dict.get("storage") {
    | Some(Object(s)) => s->Dict.get("clickhouse") == Some(Boolean(true))
    | _ => false
    }
  | _ => false
  }
  Config.incompatibleMessage(
    changedPaths,
    ~resetCommand,
    ~runCommand,
    ~hasClickhouse,
    ~addChainCommands,
  )
}
