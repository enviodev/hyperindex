type t = {
  name: string,
  initialize: (~entities: array<Internal.entityConfig>) => promise<unit>,
  resume: (
    ~frontier: Frontier.t,
    ~chains: array<Persistence.initialChainState>,
    ~entities: array<Internal.entityConfig>,
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
  ~sequence: CheckpointSequence.t,
  ~chainIdMode: ChainId.mode=Int32,
): t => {
  let sink = ClickHouse.makeSink(~host, ~username, ~password, ~database, ~chainIdMode)
  let registry = ClickHouse.makeRegistry()
  let mirrored = (entities: array<Internal.entityConfig>) =>
    entities->Array.filter(e => e.storage.clickhouse)

  {
    name: "clickhouse",
    initialize: (~entities) => {
      ClickHouse.initialize(sink, ~entities=mirrored(entities))
    },
    resume: (~frontier, ~chains, ~entities) => {
      ClickHouse.resume(sink, ~sequence, ~frontier, ~chains, ~entities=mirrored(entities))
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
