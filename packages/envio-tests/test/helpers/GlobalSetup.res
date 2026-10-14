// Vitest global setup: runs once in the main process, before any worker starts.
// A worker killed mid-test leaves its schema behind; collecting the old ones
// here is what stops them piling up in a developer's database.
let setup = async () => {
  let sql = Storage.makePgClient()
  let cleanup = async () => {
    let _ = await sql->StorageClient.close
  }
  switch await TestPgSchema.sweep(sql) {
  | _ => await cleanup()
  | exception exn =>
    await cleanup()
    throw(exn)
  }
}
