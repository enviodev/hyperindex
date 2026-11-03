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
  close: unit => promise<unit>,
}

let start: (
  ~port: int,
  ~upstreamPort: int,
) => promise<t> = %raw(`async function (port, upstreamPort) {
  const net = await import("node:net");
  let isDown = false;
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
    client.on("close", () => upstream.destroy());
    upstream.on("close", () => client.destroy());
    client.pipe(upstream);
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
    close: () =>
      new Promise((resolve) => {
        for (const socket of sockets) socket.destroy();
        server.close(() => resolve());
      }),
  };
}`)
