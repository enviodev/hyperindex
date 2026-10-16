// Vitest global setup: runs once in the main process, before any worker starts.
// A worker killed mid-test leaves its schema behind; collecting the old ones
// here is what stops them piling up in a developer's database.
@module("node:fs") external rmSync: (string, {"recursive": bool, "force": bool}) => unit = "rmSync"

let setup = async () => {
  // A failure links its run's logs here; the links a previous run printed are
  // gone with it.
  rmSync(".test-logs", {"recursive": true, "force": true})
  let sql = PgStorage.makeClient(~logger=Logging.capture())
  let cleanup = async () => {
    let _ = await sql->Sql.close
  }
  switch await TestPgSchema.sweep(sql) {
  | _ => await cleanup()
  | exception exn =>
    await cleanup()
    throw(exn)
  }
}
