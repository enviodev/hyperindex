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
    ~diffCheckpoints: array<InternalTable.Checkpoints.diffCheckpoint>,
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
  ~logger: Logger.t,
): t => {
  let logger = logger->Logger.withFields({"context": "ClickHouse"})
  let sink = ClickHouse.makeSink(~host, ~username, ~password, ~database, ~chainIdMode, ~logger)
  let registry = ClickHouse.makeRegistry()
  let mirrored = (entities: array<Internal.entityConfig>) =>
    entities->Array.filter(e => e.storage.clickhouse)

  {
    name: "clickhouse",
    initialize: (~entities) => {
      ClickHouse.initialize(sink, ~logger, ~entities=mirrored(entities))
    },
    resume: (~frontier, ~chains, ~entities) => {
      ClickHouse.resume(sink, ~logger, ~sequence, ~frontier, ~chains, ~entities=mirrored(entities))
    },
    writeBatch: async (~batch, ~diffCheckpoints, ~updatedEntities) => {
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
        ClickHouse.stageCheckpointsOrThrow(sink, ~registry, ~batch, ~diffCheckpoints)
      } catch {
      | exn =>
        sink->ClickHouseSink.discard(entities)
        throw(exn)
      }
      await ClickHouse.writeStagedOrThrow(sink, ~entities, ~checkpoints)
    },
  }
}
