type t = {
  name: string,
  initialize: (
    ~chainConfigs: array<Config.chain>=?,
    ~entities: array<Internal.entityConfig>=?,
    ~enums: array<Table.enumConfig<Table.enum>>=?,
  ) => promise<unit>,
  resume: (~checkpointId: Internal.checkpointId) => promise<unit>,
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
  // Everything the sink sends ClickHouse goes through here: the DDL and the
  // reorg cleanup as statements, the batches as RowBinary encoded off the Node
  // main thread.
  let sink = ClickHouse.makeSink(~host, ~username, ~password, ~database)
  let registry = ClickHouse.makeRegistry(~chainIdMode)

  {
    name: "clickhouse",
    initialize: (~chainConfigs as _=[], ~entities=[], ~enums=[]) => {
      ClickHouse.initialize(sink, ~registry, ~database, ~entities, ~enums, ~chainIdMode)
    },
    resume: (~checkpointId) => {
      ClickHouse.resume(sink, ~database, ~checkpointId)
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
      // Whatever staged before the failure is never written, so it is handed
      // back rather than left in the sink.
      | exn =>
        sink->ClickHouseSink.discard(entities)
        throw(exn)
      }
      await ClickHouse.writeStagedOrThrow(sink, ~entities, ~checkpoints)
    },
  }
}
