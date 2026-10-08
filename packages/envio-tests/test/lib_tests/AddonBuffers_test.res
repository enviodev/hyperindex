open Vitest

// The memory the addon lends and takes back. No indexer run can make these
// happen on demand: they guard the buffers every read and write sits on.

let client = () => PgStorage.makeClient(~maxConnections=2)

describe("Lending a result's buffers", () => {
  Async.it("Keeps the result alive when it is lent a second time", async t => {
    let pg = client()
    let result = await pg->PgClient.queryRaw("SELECT 'x'::text AS a", [])
    let buffers = pg->PgClient.lendResult(result.handle)
    let lentAgain = try {
      let _ = pg->PgClient.lendResult(result.handle)
      true
    } catch {
    | _ => false
    }
    pg->PgClient.releaseResult(result.handle, buffers)
    await pg->PgClient.close
    t.expect((lentAgain, buffers->Array.map(ArrayBuffer.byteLength))).toEqual((
      false,
      buffers->Array.map(_ => 0),
    ))
  })
})

describe("Writing a staged batch", () => {
  Async.it("Refuses a batch that was never committed, and can still abort it", async t => {
    let pg = client()
    let table = pg->PgClient.registerTable({
      tableName: "never_committed",
      columns: [{name: "id", fieldType: "String"}],
      writeColumns: ["id"],
    })
    let {handle, buffers} = pg->PgClient.beginStage(~table=table.handle, ~rows=1)
    let refused = try {
      await pg->PgClient.writeBatch(
        {
          progress: [],
          entities: [],
          chainMeta: [],
          addresses: {chainIds: [], addresses: [], contractIds: []},
          frontier: {chainIds: [], checkpointIds: []},
          checkpoints: {
            ids: [],
            chainIds: [],
            blockNumbers: [],
            blockHashes: [],
            eventsProcessed: [],
          },
          effectCaches: [{table: table.handle, create: false, rows: {staged: handle, rows: 1}}],
        },
        Null.null,
      )
      false
    } catch {
    | _ => true
    }
    pg->PgClient.abortStage(~handle, ~buffers)
    await pg->PgClient.close
    t.expect((refused, buffers->Array.map(ArrayBuffer.byteLength))).toEqual((
      true,
      buffers->Array.map(_ => 0),
    ))
  })
})

describe("Reading a bytea column", () => {
  Async.it("Keeps only the bytes the rows hold", async t => {
    let pg = client()
    let rows = await pg->PgClient.query(`SELECT '\\xdead'::bytea AS b UNION ALL SELECT '\\xbeef'::bytea`)
    await pg->PgClient.close
    let retained = rows->Array.map(
      row =>
        row
        ->Dict.getUnsafe("b")
        ->(Utils.magic: unknown => Uint8Array.t)
        ->TypedArray.buffer
        ->ArrayBuffer.byteLength,
    )
    t.expect(retained).toEqual([4, 4])
  })
})
