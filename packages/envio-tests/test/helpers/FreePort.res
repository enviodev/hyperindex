// A subgraph fixture's RPC URL is part of the config parsed while its file
// loads, before the test's own server listens, so the port has to be known
// first. A fixed one collides with whatever else on the machine holds it. A
// listener on port 0 is handed one by the OS; it runs in a child process
// because listening is asynchronous and the parse isn't, and it frees the port
// for the test's server to take.
@module("node:child_process")
external execFileSync: (string, array<string>, {"encoding": string}) => string = "execFileSync"
@val external nodePath: string = "process.execPath"

let pick = () => {
  let output = execFileSync(
    nodePath,
    [
      "-e",
      `const server = require("node:net").createServer();
server.listen(0, "127.0.0.1", () => {
  process.stdout.write(String(server.address().port));
  server.close();
});`,
    ],
    {"encoding": "utf8"},
  )
  switch output->Int.fromString {
  | Some(port) => port->Int.toString
  | None => JsError.throwWithMessage(`Expected a port number from the OS, got "${output}"`)
  }
}
