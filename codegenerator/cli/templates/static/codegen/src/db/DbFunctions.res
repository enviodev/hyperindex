type chainId = int
type eventId = string

module General = {
  type existsRes = {exists: bool}

  let hasRows = async (sql, ~table: Table.table) => {
    let query = `SELECT EXISTS(SELECT 1 FROM "${Env.Db.publicSchema}"."${table.tableName}");`
    switch await sql->Postgres.unsafe(query) {
    | [{exists}] => exists
    | _ => Js.Exn.raiseError("Unexpected result from hasRows query: " ++ query)
    }
  }
}

module EndOfBlockRangeScannedData = {
  type endOfBlockRangeScannedData = {
    @as("chain_id") chainId: int,
    @as("block_number") blockNumber: int,
    @as("block_hash") blockHash: string,
  }

  @module("./DbFunctionsImplementation.js")
  external batchSet: (Postgres.sql, array<endOfBlockRangeScannedData>) => promise<unit> =
    "batchSetEndOfBlockRangeScannedData"

  let setEndOfBlockRangeScannedData = (sql, endOfBlockRangeScannedData) =>
    batchSet(sql, [endOfBlockRangeScannedData])

  @module("./DbFunctionsImplementation.js")
  external readEndOfBlockRangeScannedDataForChain: (
    Postgres.sql,
    ~chainId: int,
  ) => promise<array<endOfBlockRangeScannedData>> = "readEndOfBlockRangeScannedDataForChain"

  @module("./DbFunctionsImplementation.js")
  external deleteStaleEndOfBlockRangeScannedDataForChain: (
    Postgres.sql,
    ~chainId: int,
    //minimum blockNumber that should be kept in db
    ~blockNumberThreshold: int,
  ) => promise<unit> = "deleteStaleEndOfBlockRangeScannedDataForChain"

  @module("./DbFunctionsImplementation.js")
  external rollbackEndOfBlockRangeScannedDataForChain: (
    Postgres.sql,
    ~chainId: int,
    //The known block number we are rollbacking to
    ~knownBlockNumber: int,
  ) => promise<unit> = "rollbackEndOfBlockRangeScannedDataForChain"
}

module DynamicContractRegistry = {
  @module("./DbFunctionsImplementation.js")
  external readAllDynamicContractsRaw: (Postgres.sql, ~chainId: chainId) => promise<Js.Json.t> =
    "readAllDynamicContracts"

  let readAllDynamicContracts = async (sql: Postgres.sql, ~chainId: chainId) => {
    let json = await sql->readAllDynamicContractsRaw(~chainId)
    json->S.parseJsonOrThrow(InternalTable.DynamicContractRegistry.rowsSchema)
  }
}

module EntityHistory = {
  type dynamicSqlQuery
  module UnorderedMultichain = {
    @module("./DbFunctionsImplementation.js")
    external getFirstChangeSerial: (
      Postgres.sql,
      ~reorgChainId: int,
      ~safeBlockNumber: int,
      ~entityName: string,
    ) => dynamicSqlQuery = "getFirstChangeSerial_UnorderedMultichain"
  }

  module OrderedMultichain = {
    @module("./DbFunctionsImplementation.js")
    external getFirstChangeSerial: (
      Postgres.sql,
      ~safeBlockTimestamp: int,
      ~reorgChainId: int,
      ~safeBlockNumber: int,
      ~entityName: string,
    ) => dynamicSqlQuery = "getFirstChangeSerial_OrderedMultichain"
  }

  @module("./DbFunctionsImplementation.js")
  external getFirstChangeEntityHistoryPerChain: (
    Postgres.sql,
    ~entityName: string,
    ~getFirstChangeSerial: Postgres.sql => dynamicSqlQuery,
  ) => promise<Js.Json.t> = "getFirstChangeEntityHistoryPerChain"

  @module("./DbFunctionsImplementation.js")
  external getRollbackDiffInternal: (
    Postgres.sql,
    ~entityName: string,
    ~getFirstChangeSerial: Postgres.sql => dynamicSqlQuery,
  ) => //Returns an array of entity history rows
  promise<Js.Json.t> = "getRollbackDiff"

  @module("./DbFunctionsImplementation.js")
  external deleteRolledBackEntityHistory: (
    Postgres.sql,
    ~entityName: string,
    ~getFirstChangeSerial: Postgres.sql => dynamicSqlQuery,
  ) => promise<unit> = "deleteRolledBackEntityHistory"

  let rollbacksGroup = "Rollbacks"

  module Args = {
    type t =
      | OrderedMultichain({safeBlockTimestamp: int, reorgChainId: int, safeBlockNumber: int})
      | UnorderedMultichain({reorgChainId: int, safeBlockNumber: int})

    /**
    Uses two different methods for determining the first change event after rollback block

    This is needed since unordered multichain mode only cares about any changes that 
    occurred after the first change on the reorg chain. To prevent skipping or double processing events
    on the other chains. If for instance there are no entity changes based on the reorg chain, the other
    chains do not need to be rolled back, and if the reorg chain has new included events, it does not matter
    that if those events are processed out of order from other chains since this is "unordered_multichain_mode"

    Ordered multichain mode needs to ensure that all chains rollback to any event that occurred after the reorg chain
    block number. Regardless of whether the reorg chain incurred any changes or not to entities.
    */
    let makeGetFirstChangeSerial = (self: t, ~entityName) =>
      switch self {
      | OrderedMultichain({safeBlockTimestamp, reorgChainId, safeBlockNumber}) =>
        sql =>
          OrderedMultichain.getFirstChangeSerial(
            sql,
            ~safeBlockTimestamp,
            ~reorgChainId,
            ~safeBlockNumber,
            ~entityName,
          )
      | UnorderedMultichain({reorgChainId, safeBlockNumber}) =>
        sql =>
          UnorderedMultichain.getFirstChangeSerial(
            sql,
            ~reorgChainId,
            ~safeBlockNumber,
            ~entityName,
          )
      }

    let getLogger = (self: t, ~entityName) => {
      switch self {
      | OrderedMultichain({safeBlockTimestamp, reorgChainId, safeBlockNumber}) =>
        Logging.createChild(
          ~params={
            "type": "OrderedMultichain",
            "safeBlockTimestamp": safeBlockTimestamp,
            "reorgChainId": reorgChainId,
            "safeBlockNumber": safeBlockNumber,
            "entityName": entityName,
          },
        )
      | UnorderedMultichain({reorgChainId, safeBlockNumber}) =>
        Logging.createChild(
          ~params={
            "type": "UnorderedMultichain",
            "reorgChainId": reorgChainId,
            "safeBlockNumber": safeBlockNumber,
            "entityName": entityName,
          },
        )
      }
    }
  }

  let deleteAllEntityHistoryAfterEventIdentifier = async (
    sql,
    ~isUnorderedMultichainMode,
    ~eventIdentifier: Types.eventIdentifier,
    ~allEntities=Entities.allEntities,
  ): unit => {
    let startTime = Hrtime.makeTimer()

    let {chainId, blockNumber, blockTimestamp} = eventIdentifier
    let args: Args.t = isUnorderedMultichainMode
      ? UnorderedMultichain({reorgChainId: chainId, safeBlockNumber: blockNumber})
      : OrderedMultichain({
          reorgChainId: chainId,
          safeBlockNumber: blockNumber,
          safeBlockTimestamp: blockTimestamp,
        })

    let _ =
      await allEntities
      ->Belt.Array.map(async entityConfig => {
        try await deleteRolledBackEntityHistory(
          sql,
          ~entityName=entityConfig.name,
          ~getFirstChangeSerial=args->Args.makeGetFirstChangeSerial(~entityName=entityConfig.name),
        ) catch {
        | exn =>
          exn->ErrorHandling.mkLogAndRaise(
            ~msg=`Failed to delete rolled back entity history`,
            ~logger=args->Args.getLogger(~entityName=entityConfig.name),
          )
        }
      })
      ->Promise.all

    if Env.Benchmark.shouldSaveData {
      let elapsedTimeMillis = Hrtime.timeSince(startTime)->Hrtime.toMillis->Hrtime.floatFromMillis

      Benchmark.addSummaryData(
        ~group=rollbacksGroup,
        ~label=`Delete Rolled Back History Time (ms)`,
        ~value=elapsedTimeMillis,
      )
    }
  }

  let getRollbackDiff = async (sql, args: Args.t, ~entityConfig: Internal.entityConfig) => {
    let startTime = Hrtime.makeTimer()

    let diffRes = switch await getRollbackDiffInternal(
      sql,
      ~getFirstChangeSerial=args->Args.makeGetFirstChangeSerial(~entityName=entityConfig.name),
      ~entityName=entityConfig.name,
    ) {
    | exception exn =>
      exn->ErrorHandling.mkLogAndRaise(
        ~msg="Failed to get rollback diff from entity history",
        ~logger=args->Args.getLogger(~entityName=entityConfig.name),
      )
    | res => res
    }

    if Env.Benchmark.shouldSaveData {
      let elapsedTimeMillis = Hrtime.timeSince(startTime)->Hrtime.toMillis->Hrtime.floatFromMillis

      Benchmark.addSummaryData(
        ~group=rollbacksGroup,
        ~label=`Diff Creation Time (ms)`,
        ~value=elapsedTimeMillis,
      )
    }

    switch diffRes->S.parseOrThrow(entityConfig.entityHistory.schemaRows) {
    | exception exn =>
      exn->ErrorHandling.mkLogAndRaise(
        ~msg="Failed to parse rollback diff from entity history",
        ~logger=args->Args.getLogger(~entityName=entityConfig.name),
      )
    | diffRows => diffRows
    }
  }

  module FirstChangeEventPerChain = {
    type t = Js.Dict.t<FetchState.blockNumberAndLogIndex>
    let getKey = chainId => chainId->Belt.Int.toString
    let make = () => Js.Dict.empty()
    let get = (self: t, ~chainId) => self->Utils.Dict.dangerouslyGetNonOption(getKey(chainId))

    let setIfEarlier = (self: t, ~chainId, ~event: FetchState.blockNumberAndLogIndex) => {
      let chainKey = chainId->Belt.Int.toString
      switch self->Utils.Dict.dangerouslyGetNonOption(chainKey) {
      | Some(existingEvent) =>
        if (
          (event.blockNumber, event.logIndex) < (existingEvent.blockNumber, existingEvent.logIndex)
        ) {
          self->Js.Dict.set(chainKey, event)
        }
      | None => self->Js.Dict.set(chainKey, event)
      }
    }
  }

  let getFirstChangeEventPerChain = async (
    sql,
    args: Args.t,
    ~allEntities=Entities.allEntities,
  ) => {
    let startTime = Hrtime.makeTimer()
    let firstChangeEventPerChain = FirstChangeEventPerChain.make()

    let _ =
      await allEntities
      ->Belt.Array.map(async entityConfig => {
        let res = try await getFirstChangeEntityHistoryPerChain(
          sql,
          ~entityName=entityConfig.name,
          ~getFirstChangeSerial=args->Args.makeGetFirstChangeSerial(~entityName=entityConfig.name),
        ) catch {
        | exn =>
          exn->ErrorHandling.mkLogAndRaise(
            ~msg=`Failed to get first change entity history per chain for entity`,
            ~logger=args->Args.getLogger(~entityName=entityConfig.name),
          )
        }

        let chainHistoryRows = try res->S.parseOrThrow(
          entityConfig.entityHistory.schemaRows,
        ) catch {
        | exn =>
          exn->ErrorHandling.mkLogAndRaise(
            ~msg=`Failed to parse entity history rows from db on getFirstChangeEntityHistoryPerChain`,
            ~logger=args->Args.getLogger(~entityName=entityConfig.name),
          )
        }

        chainHistoryRows->Belt.Array.forEach(chainHistoryRow => {
          firstChangeEventPerChain->FirstChangeEventPerChain.setIfEarlier(
            ~chainId=chainHistoryRow.current.chain_id,
            ~event={
              blockNumber: chainHistoryRow.current.block_number,
              logIndex: chainHistoryRow.current.log_index,
            },
          )
        })
      })
      ->Promise.all

    if Env.Benchmark.shouldSaveData {
      let elapsedTimeMillis = Hrtime.timeSince(startTime)->Hrtime.toMillis->Hrtime.floatFromMillis

      Benchmark.addSummaryData(
        ~group=rollbacksGroup,
        ~label=`Get First Change Event Per Chain Time (ms)`,
        ~value=elapsedTimeMillis,
      )
    }

    firstChangeEventPerChain
  }

  let hasRows = async sql => {
    let all =
      await Entities.allEntities
      ->Belt.Array.map(async entityConfig => {
        try await General.hasRows(sql, ~table=entityConfig.entityHistory.table) catch {
        | exn =>
          exn->ErrorHandling.mkLogAndRaise(
            ~msg=`Failed to check if entity history table has rows`,
            ~logger=Logging.createChild(
              ~params={
                "entityName": entityConfig.name,
              },
            ),
          )
        }
      })
      ->Promise.all
    all->Belt.Array.some(v => v)
  }
}
