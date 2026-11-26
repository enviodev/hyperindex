// A chain as its storage holds it: what its `envio_chains` row keeps of its
// config.
type storedChain = {
  id: ChainId.t,
  startBlock: int,
  endBlock: option<int>,
  maxReorgDepth: int,
}

// What a storage holds of the config it was built from. `envioInfo` is `None`
// for a storage an older envio built, which kept no such record.
type stored = {
  envioInfo: option<JSON.t>,
  chains: array<storedChain>,
  contractMapping: ContractMapping.t,
  // The chains that still owe the events an earlier config change added their
  // history.
  addedEventsChainIds: array<ChainId.t>,
}

// The events contracts gained since the storage was built, by contract name.
type addedEvents = dict<array<string>>

type t =
  | Resume
  // Configured since the storage was built, and the only chain its
  // `envio start --chain` process drives.
  | AddChain(Config.chain)
  // Events on contracts the storage already knows, in a run started with
  // `--backfill-added-events`.
  | AddEvents(addedEvents)
  | Incompatible(array<string>)

// The part of a chain's config its storage keeps, shaped so a stored chain and
// a configured one diff by the path config.yaml spells: `chains.137.endBlock`.
let chainEntry = (~startBlock: option<int>, ~endBlock: option<int>, ~maxReorgDepth: int) => {
  let entry = dict{"maxReorgDepth": JSON.Number(maxReorgDepth->Int.toFloat)}
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

%%private(
  let eventName = (event: JSON.t) =>
    switch event {
    | Object(fields) =>
      switch fields->Dict.get("name") {
      | Some(String(name)) => Some(name)
      | _ => None
      }
    | _ => None
    }
)

%%private(
  let eventsOf = (contract: dict<JSON.t>) =>
    switch contract->Dict.get("events") {
    | Some(Array(events)) => events
    | _ => []
    }
)

%%private(
  let isSubsetOfAbi = (~stored: array<JSON.t>, ~current: array<JSON.t>) => {
    let spell = item => item->Config.canonicalJson->JSON.stringify
    let currentItems = Utils.Set.fromArray(current->Array.map(spell))
    stored->Array.every(item => currentItems->Utils.Set.has(item->spell))
  }
)

// The record `current` would leave without the events its contracts gained
// over `stored`, with those events and the paths config.yaml spells them by.
// An event is told apart by its name, and the events both hold are put in the
// stored order, so a new event listed ahead of an old one doesn't read as a
// change to the old one. A contract only one of the two declares is left as it
// is, for the comparison to report.
let withoutAddedEvents = (~stored: JSON.t, ~current: JSON.t) => {
  let addedEvents: addedEvents = Dict.make()
  let paths = []
  let withoutAdded = switch (stored, current) {
  | (Object(storedFields), Object(currentFields)) =>
    let rebuilt = currentFields->Dict.copy
    Config.ecosystemFields->Array.forEach(ecosystem =>
      switch (storedFields->Dict.get(ecosystem), currentFields->Dict.get(ecosystem)) {
      | (Some(Object(storedEcosystem)), Some(Object(currentEcosystem))) =>
        switch (storedEcosystem->Dict.get("contracts"), currentEcosystem->Dict.get("contracts")) {
        | (Some(Object(storedContracts)), Some(Object(currentContracts))) =>
          let rebuiltContracts = currentContracts->Dict.copy
          currentContracts->Dict.forEachWithKey((contract, contractName) =>
            switch (storedContracts->Dict.get(contractName), contract) {
            | (Some(Object(storedContract)), Object(currentContract)) =>
              let storedEvents = storedContract->eventsOf
              let currentEvents = currentContract->eventsOf
              let storedNames = Utils.Set.fromArray(storedEvents->Array.filterMap(eventName))
              let added =
                currentEvents
                ->Array.filterMap(eventName)
                ->Array.filter(name => !(storedNames->Utils.Set.has(name)))
              if added->Utils.Array.notEmpty {
                addedEvents->Dict.set(contractName, added)
                added->Array.forEach(
                  name =>
                    paths
                    ->Array.push(`${ecosystem}.contracts.${contractName}.events.${name}`)
                    ->ignore,
                )
                let rebuiltContract = currentContract->Dict.copy
                rebuiltContract->Dict.set(
                  "events",
                  Array(
                    storedEvents->Array.filterMap(
                      storedEvent =>
                        currentEvents->Array.find(
                          event => event->eventName == storedEvent->eventName,
                        ),
                    ),
                  ),
                )
                switch (storedContract->Dict.get("abi"), currentContract->Dict.get("abi")) {
                | (Some(Array(storedAbi)), Some(Array(currentAbi)))
                  if isSubsetOfAbi(~stored=storedAbi, ~current=currentAbi) =>
                  rebuiltContract->Dict.set("abi", Array(storedAbi))
                | _ => ()
                }
                rebuiltContracts->Dict.set(contractName, Object(rebuiltContract))
              }
            | _ => ()
            }
          )
          let rebuiltEcosystem = currentEcosystem->Dict.copy
          rebuiltEcosystem->Dict.set("contracts", Object(rebuiltContracts))
          rebuilt->Dict.set(ecosystem, Object(rebuiltEcosystem))
        | _ => ()
        }
      | _ => ()
      }
    )
    JSON.Object(rebuilt)
  | _ => current
  }
  (withoutAdded, addedEvents, paths)
}

// `envioInfo` is the running config's, `chainConfigs` the chains this process
// drives. An isolated process answers for `envioInfo` and its own chains only:
// the ones it leaves out are checked, and added, by the processes that drive
// them.
let make = (
  ~stored: stored,
  ~envioInfo: JSON.t,
  ~chainConfigs: array<Config.chain>,
  ~contractMapping: ContractMapping.t,
  ~isolated: bool,
  ~backfillAddedEvents=false,
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
    let storedEntries =
      storedChains->Array.map(storedChain => (
        storedChain.id,
        chainEntry(
          ~startBlock=Some(storedChain.startBlock),
          ~endBlock=storedChain.endBlock,
          ~maxReorgDepth=storedChain.maxReorgDepth,
        ),
      ))
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
          ),
        ))
      }
    )
    let changedPaths = Config.diffPaths(
      ~stored=storedEnvioInfo->withChains(~chains=storedEntries),
      ~current=envioInfo->withChains(~chains=currentEntries),
    )
    let hasSameContracts = stored.contractMapping->ContractMapping.isEqual(contractMapping)
    let changedPaths = hasSameContracts ? changedPaths : changedPaths->Array.concat(["contracts"])
    switch (changedPaths, added) {
    | ([], None) => Resume
    | ([], Some(chain)) => AddChain(chain)
    | (changedPaths, None) if hasSameContracts =>
      let (withoutAdded, addedEvents, addedEventPaths) = withoutAddedEvents(
        ~stored=storedEnvioInfo,
        ~current=envioInfo,
      )
      let isOnlyChange =
        addedEventPaths->Utils.Array.notEmpty &&
          Config.diffPaths(
            ~stored=storedEnvioInfo->withChains(~chains=storedEntries),
            ~current=withoutAdded->withChains(~chains=currentEntries),
          )->Utils.Array.isEmpty
      switch (isOnlyChange, backfillAddedEvents) {
      | (true, true) => AddEvents(addedEvents)
      | (true, false) => Incompatible(addedEventPaths)
      | (false, _) => Incompatible(changedPaths)
      }
    | (changedPaths, _) => Incompatible(changedPaths)
    }
  }

// Whether the events config.yaml gained are the whole of what changed, which
// is when `--backfill-added-events` can take them.
let isAddedEventsOnlyChange = (
  ~stored: stored,
  ~envioInfo: JSON.t,
  ~chainConfigs: array<Config.chain>,
  ~contractMapping: ContractMapping.t,
  ~isolated: bool,
) =>
  switch make(
    ~stored,
    ~envioInfo,
    ~chainConfigs,
    ~contractMapping,
    ~isolated,
    ~backfillAddedEvents=true,
  ) {
  | AddEvents(_) => true
  | Resume | AddChain(_) | Incompatible(_) => false
  }

// Why the added events can't be taken into this storage, when they can't.
let addedEventsRefusal = (stored: stored, ~envioInfo: JSON.t) =>
  switch stored.addedEventsChainIds {
  | [] =>
    switch envioInfo {
    | Object(fields)
      if switch fields->Dict.get("storage") {
      | Some(Object(storage)) => storage->Dict.get("clickhouse") == Some(Boolean(true))
      | _ => false
      } =>
      Some(
        "`--backfill-added-events` doesn't support ClickHouse storage yet: its rows are kept by checkpoint, and the added events are indexed outside the chain's checkpoint order.",
      )
    | Object(fields) if fields->Dict.get("saveFullHistory") == Some(Boolean(true)) =>
      Some(
        "`--backfill-added-events` can't be used with `save_full_history: true`: the added events are indexed after the ones already stored, so their rows can't join a history kept in block order.",
      )
    | _ => None
    }
  | chainIds =>
    Some(
      `An earlier \`--backfill-added-events\` run hasn't finished on chain ${chainIds
        ->Array.map(ChainId.toString)
        ->Array.join(
          ", ",
        )}. Start the indexer with the config that run used and let it finish before adding more events.`,
    )
  }

// The paths of the config addresses each resumed chain gained or lost since it
// was stored, as config.yaml spells them: `chains.137.contracts.Token.addresses.0x…`.
// A chain's stored rows are read whole to resume it, and its config ones are
// those no event registered, so this reads nothing of its own.
let changedConfigAddressPaths = (
  resumedChains: array<(Config.chain, AddressRows.seedRows)>,
  ~ecosystem: string,
  ~contractMapping: ContractMapping.t,
  ~lowercaseAddresses: bool,
) => {
  let entry = (addresses: array<(string, string)>) => {
    let contracts = Dict.make()
    addresses->Array.forEach(((contractName, address)) =>
      contracts->Utils.Dict.push(contractName, address)
    )
    JSON.Object(
      dict{
        "contracts": JSON.Object(
          contracts->Dict.mapValues(addresses => JSON.Object(
            dict{
              "addresses": JSON.Object(
                addresses->Array.map(address => (address, JSON.Boolean(true)))->Dict.fromArray,
              ),
            },
          )),
        ),
      },
    )
  }
  let storedEntries = resumedChains->Array.map(((chain, seedRows)) => {
    let configRows = []
    seedRows.registrationBlocks->Array.forEachWithIndex((registrationBlock, idx) =>
      if registrationBlock === AddressRows.configRegistrationBlock {
        configRows
        ->Array.push(
          (
            {
              chainId: chain.id,
              address: seedRows.addresses->Array.getUnsafe(idx),
              contractId: seedRows.contractIds->Array.getUnsafe(idx),
              registrationBlock,
            }: AddressRows.row
          ),
        )
        ->ignore
      }
    )
    let addresses =
      configRows
      ->AddressRows.render(~ecosystem, ~shouldChecksum=!lowercaseAddresses)
      ->Array.mapWithIndex((address, idx) => (
        contractMapping->ContractMapping.nameOfOrThrow(
          (configRows->Array.getUnsafe(idx)).contractId,
        ),
        address->Address.toString,
      ))
    (chain.id, entry(addresses))
  })
  let currentEntries =
    resumedChains->Array.map(((chain, _)) => (
      chain.id,
      entry(
        chain.contracts->Array.flatMap(contract =>
          contract.addresses->Array.map(address => (contract.name, address->Address.toString))
        ),
      ),
    ))
  Config.diffPaths(
    ~stored=JSON.Object(dict{})->withChains(~chains=storedEntries),
    ~current=JSON.Object(dict{})->withChains(~chains=currentEntries),
  )
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
) => {
  let newChains =
    chainConfigs->Array.filter(chain =>
      !(stored.chains->Array.some(storedChain => storedChain.id == chain.id))
    )
  let isNewChainPath = path =>
    newChains->Array.some(chain => path == `chains.${chain.id->ChainId.toString}`)
  let addsAlone = chain =>
    switch make(~stored, ~envioInfo, ~chainConfigs=[chain], ~contractMapping, ~isolated=true) {
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
  ~backfillAddedEventsCommand: option<string>=?,
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
    ~backfillAddedEventsCommand?,
  )
}
