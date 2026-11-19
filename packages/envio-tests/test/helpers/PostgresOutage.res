// A TCP proxy in front of the test Postgres that a test can take down and bring
// back. While down it drops every connection it carries and accepts new ones
// only to close them straight away, as PgBouncer, a cloud SQL proxy or Docker's
// port proxy does in front of a restarting database.
//
// The port is fixed per file: `Scenario.it` takes it while vitest collects,
// before any hook could report a random one.
type t = {
  goDown: unit => unit,
  comeBack: unit => unit,
  // Cuts the connection that next sends a COMMIT, before the client hears
  // back. With `~deliver` the server gets the COMMIT and commits; without it the
  // COMMIT is dropped and the server rolls back. `~holdUntil` holds the
  // transaction open until the promise resolves, as a slow network would.
  // Either way the client only sees its connection go.
  cutNextCommit: (~deliver: bool, ~holdUntil: promise<unit>=?) => unit,
  close: unit => promise<unit>,
}

let start: (
  ~port: int,
  ~upstreamPort: int,
) => promise<t> = %raw(`async function (port, upstreamPort) {
  const net = await import("node:net");
  let isDown = false;
  let commitCut = null;
  // A simple-query COMMIT as the wire carries it: 'Q', length, text, NUL.
  const commitMessage = Buffer.concat([Buffer.from("Q"), Buffer.from([0, 0, 0, 11]), Buffer.from("COMMIT\0")]);
  const sockets = new Set();
  const track = (socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.on("error", () => socket.destroy());
  };
  const server = net.createServer((client) => {
    track(client);
    if (isDown) {
      client.destroy();
      return;
    }
    const upstream = net.connect(upstreamPort, "127.0.0.1");
    track(upstream);
    const closeUpstream = () => upstream.destroy();
    client.on("close", closeUpstream);
    upstream.on("close", () => client.destroy());
    client.on("data", (chunk) => {
      if (commitCut && chunk.includes(commitMessage)) {
        const { deliver, holdUntil } = commitCut;
        commitCut = null;
        upstream.unpipe(client);
        // The upstream outlives the client here, so the COMMIT reaches the server.
        client.off("close", closeUpstream);
        client.destroy();
        const settle = () => (deliver ? upstream.end(chunk) : upstream.destroy());
        if (holdUntil) holdUntil.then(settle);
        else settle();
        return;
      }
      upstream.write(chunk);
    });
    upstream.pipe(client);
  });
  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));
  return {
    goDown: () => {
      isDown = true;
      for (const socket of sockets) socket.destroy();
    },
    comeBack: () => {
      isDown = false;
    },
    cutNextCommit: (deliver, holdUntil) => {
      commitCut = { deliver, holdUntil };
    },
    close: () =>
      new Promise((resolve) => {
        for (const socket of sockets) socket.destroy();
        server.close(() => resolve());
      }),
  };
}`)
