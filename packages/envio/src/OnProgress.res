// Builds the post-write hook that drives `indexer.onProgress`. Returns `None`
// when nothing is registered so the write loop skips the work entirely.
let makeInvoker = (~handlers: array<Internal.onProgress>): option<
  InMemoryStore.onProgressInvoker,
> => {
  switch handlers {
  | [] => None
  | handlers =>
    Some(
      (~progressedChainsById, ~chains, ~rollback) =>
        progressedChainsById
        ->Utils.Dict.mapValuesToArray((chainAfterBatch: Batch.chainAfterBatch) => {
          let chainId = chainAfterBatch.fetchState.chainId
          let chain = switch chains->Utils.Dict.dangerouslyGetByIntNonOption(chainId) {
          | Some(chain) => chain
          | None => ({id: chainId, isRealtime: false}: Internal.chainInfo)
          }
          let context: Envio.onProgressContext = {
            log: Logging.createChild(~params={"chainId": chainId})->Logging.toUserLogger,
            chain,
          }
          let rollbackToBlock = switch rollback {
          | Some(rollback: Persistence.rollback) =>
            rollback.progressBlockNumberByChainId->Utils.Dict.dangerouslyGetByIntNonOption(chainId)
          | None => None
          }
          let args: Internal.onProgressArgs = {
            context: context->(Utils.magic: Envio.onProgressContext => Internal.onProgressContext),
            ?rollbackToBlock,
          }
          handlers->Array.map(handler => handler(args))->Promise.all
        })
        ->Promise.all
        ->Promise.thenResolve(_ => ()),
    )
  }
}
