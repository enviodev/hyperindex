type t = {
  name: string,
  initialize: (~entities: array<Internal.entityConfig>) => promise<unit>,
  resume: (
    ~checkpointId: Internal.checkpointId,
    ~chains: array<Persistence.initialChainState>,
  ) => promise<unit>,
  writeBatch: (
    ~batch: Batch.t,
    ~updatedEntities: array<Persistence.updatedEntity>,
  ) => promise<unit>,
}

let makeClickHouse = (
  ~host,
  ~database,
  ~username,
  ~password,
  ~chainIdMode: ChainId.mode=Int32,
): t => {
  let sink = ClickHouse.makeSink(~host, ~username, ~password, ~database, ~chainIdMode)
  let registry = ClickHouse.makeRegistry()

  {
    name: "clickhouse",
    initialize: (~entities) => {
      ClickHouse.initialize(sink, ~entities)
    },
    resume: (~checkpointId, ~chains) => {
      ClickHouse.resume(sink, ~checkpointId, ~chains)
    },
    writeBatch: async (~batch, ~updatedEntities) => {
      // Staging reads JS values, so it holds the isolate and runs here. The
      // encode and the round trips happen in Rust, which also keeps the
      // checkpoints behind the rows they cover.
      let entities = []
      let checkpoints = try {
        updatedEntities->Array.forEach(({entityConfig, scope, changes}) =>
          switch ClickHouse.stageUpdatesOrThrow(sink, ~registry, ~changes, ~entityConfig, ~scope) {
          | Some(handle) => entities->Array.push(handle)
          | None => ()
          }
        )
        ClickHouse.stageCheckpointsOrThrow(sink, ~registry, ~batch)
      } catch {
      | exn =>
        sink->ClickHouseSink.discard(entities)
        throw(exn)
      }
      await ClickHouse.writeStagedOrThrow(sink, ~entities, ~checkpoints)
    },
  }
}
