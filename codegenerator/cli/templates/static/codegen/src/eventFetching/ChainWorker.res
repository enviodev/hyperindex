@@warning("-27")
module type S = {
  type t

  let make: (
    ~caughtUpToHeadHook: t => promise<unit>=?,
    ~contractAddressMapping: ContractAddressingMap.mapping=?,
    Config.chainConfig,
  ) => t

  let stopFetchingEvents: t => promise<unit>

  let startWorker: (
    t,
    ~startBlock: int,
    ~logger: Pino.t,
    ~fetchedEventQueue: ChainEventQueue.t,
    ~checkHasReorgOccurred: (
      ReorgDetection.lastBlockScannedData,
      ~parentHash: option<string>,
      ~currentHeight: int,
    ) => unit,
  ) => promise<unit>

  let startFetchingEvents: (
    t,
    ~logger: Pino.t,
    ~fetchedEventQueue: ChainEventQueue.t,
    ~checkHasReorgOccurred: (
      ReorgDetection.lastBlockScannedData,
      ~parentHash: option<string>,
      ~currentHeight: int,
    ) => unit,
  ) => promise<unit>

  let addNewRangeQueriedCallback: t => promise<unit>

  let getLatestFetchedBlockTimestamp: t => int

  let addDynamicContractAndFetchMissingEvents: (
    t,
    ~dynamicContracts: array<Types.dynamicContractRegistryEntity>,
    ~fromBlock: int,
    ~fromLogIndex: int,
    ~logger: Pino.t,
  ) => promise<array<Types.eventBatchQueueItem>>

  let getCurrentBlockHeight: t => int
}

@@warnings("+27")

type chainWorker =
  | Rpc(RpcWorker.t)
  | HyperSync(HyperSyncWorker.t)
  | RawEvents(RawEventsWorker.t)

module PolyMorphicChainWorkerFunctions = {
  /* Why use thes polymorphic functions rather than calling function directly on
  the chainworker?

  We could just call the function on the worker when matching on the chainWorker type.
  ie. ... | Rpc(worker) => worker->RpcWorker.startFetchingEvents() ...

  Instead we have these polymorphic functions that take a tuple with worker with it's module type,
  and calls the chain worker function.

  The only real benefit is that it forces us to use functions on the ChainWorker module signature.
  Which will hopefully keep this somewhat modular. 

  The chainworkerModTuple type enforces that the worker type and module conform to the chainworker 
  signature. And the polymorphic functions only call functions on that signature.

  chainWorker variants can be converted to this type, and used with the polymorphic functions.

  It's not the prettiest interface, and if readability is ever chosen over this enforced module signature
  pattern then these polymorphic functions can be removed and the functions can be accessed/called directly
  on the underlying worker module.
 */

  type chainWorkerModTuple<'workerType> = ('workerType, module(S with type t = 'workerType))

  /**
  First class polymorphic functions do not exist in OCaml. IE we can't pass a polymorphic function
  as a param to another function and still use it polymorphically within scope of that function.

  There is a workaround to use "explicit universally quantified" param (using the "." after the type in do)
  inside a record. 

  This allows us to call "do" as if it were a first class polymorphic function when it gets
  passed to another function
  */
  type firstClassPoly<'a> = {do: 'workerType. chainWorkerModTuple<'workerType> => 'a}

  let startWorker = {
    do: (type workerType, chainWorkerModTuple: chainWorkerModTuple<workerType>) => {
      let (worker, workerMod) = chainWorkerModTuple
      let module(ChainWorker) = workerMod
      worker->ChainWorker.startWorker
    },
  }

  let startFetchingEvents = {
    do: (type workerType, chainWorkerModTuple: chainWorkerModTuple<workerType>) => {
      let (worker, workerMod) = chainWorkerModTuple
      let module(ChainWorker) = workerMod
      worker->ChainWorker.startFetchingEvents
    },
  }

  let addNewRangeQueriedCallback = {
    do: (type workerType, chainWorkerModTuple: chainWorkerModTuple<workerType>) => {
      let (worker, workerMod) = chainWorkerModTuple
      let module(M) = workerMod
      worker->M.addNewRangeQueriedCallback
    },
  }

  let getLatestFetchedBlockTimestamp = {
    do: (type workerType, chainWorkerModTuple: chainWorkerModTuple<workerType>) => {
      let (worker, workerMod) = chainWorkerModTuple
      let module(M) = workerMod
      worker->M.getLatestFetchedBlockTimestamp
    },
  }

  let addDynamicContractAndFetchMissingEvents = {
    do: (type workerType, chainWorkerModTuple: chainWorkerModTuple<workerType>) => {
      let (worker, workerMod) = chainWorkerModTuple
      let module(M) = workerMod
      worker->M.addDynamicContractAndFetchMissingEvents
    },
  }

  let getCurrentBlockHeight = {
    do: (type workerType, chainWorkerModTuple: chainWorkerModTuple<workerType>) => {
      let (worker, workerMod) = chainWorkerModTuple
      let module(M) = workerMod
      worker->M.getCurrentBlockHeight
    },
  }

  type chainWorkerMod =
    | RpcWorkerMod(chainWorkerModTuple<RpcWorker.t>)
    | HyperSyncWorkerMod(chainWorkerModTuple<HyperSyncWorker.t>)
    | RawEventsWorkerMod(chainWorkerModTuple<RawEventsWorker.t>)

  let chainWorkerToChainMod = (worker: chainWorker) => {
    switch worker {
    | HyperSync(w) => HyperSyncWorkerMod((w, module(HyperSyncWorker)))
    | Rpc(w) => RpcWorkerMod((w, module(RpcWorker)))
    | RawEvents(w) => RawEventsWorkerMod((w, module(RawEventsWorker)))
    }
  }

  /**
  Takes a firstClassPoly and composes it with a chainWorker type
  */
  let polyComposer = (f, worker: chainWorker) => {
    switch worker->chainWorkerToChainMod {
    | RpcWorkerMod(w) => f.do(w)
    | HyperSyncWorkerMod(w) => f.do(w)
    | RawEventsWorkerMod(w) => f.do(w)
    }
  }
}

let {
  polyComposer,
  startWorker,
  startFetchingEvents,
  addNewRangeQueriedCallback,
  getLatestFetchedBlockTimestamp,
  addDynamicContractAndFetchMissingEvents,
  getCurrentBlockHeight,
} = module(PolyMorphicChainWorkerFunctions)

let startWorker = polyComposer(startWorker)
let startFetchingEvents = polyComposer(startFetchingEvents)
let addNewRangeQueriedCallback = polyComposer(addNewRangeQueriedCallback)
let getLatestFetchedBlockTimestamp = polyComposer(getLatestFetchedBlockTimestamp)
let addDynamicContractAndFetchMissingEvents = polyComposer(addDynamicContractAndFetchMissingEvents)
let getCurrentBlockHeight = polyComposer(getCurrentBlockHeight)

type caughtUpToHeadCallback<'worker> = option<'worker => promise<unit>>
type workerSelectionWithCallback =
  | RpcSelectedWithCallback(caughtUpToHeadCallback<RpcWorker.t>)
  | HyperSyncSelectedWithCallback(caughtUpToHeadCallback<HyperSyncWorker.t>)
  | RawEventsSelectedWithCallback(caughtUpToHeadCallback<RawEventsWorker.t>)

let make = (
  ~chainConfig,
  ~contractAddressMapping=?,
  selectedWorker: workerSelectionWithCallback,
) => {
  switch selectedWorker {
  | RpcSelectedWithCallback(caughtUpToHeadHook) =>
    Rpc(RpcWorker.make(~caughtUpToHeadHook?, ~contractAddressMapping?, chainConfig))
  | HyperSyncSelectedWithCallback(caughtUpToHeadHook) =>
    HyperSync(HyperSyncWorker.make(~caughtUpToHeadHook?, ~contractAddressMapping?, chainConfig))
  | RawEventsSelectedWithCallback(caughtUpToHeadHook) =>
    RawEvents(RawEventsWorker.make(~caughtUpToHeadHook?, ~contractAddressMapping?, chainConfig))
  }
}
