// A local HTTP proxy to a live HyperSync or JSON-RPC endpoint. A config.yaml
// pointing a chain at it runs the real source against the real server, while
// the proxy keeps every request body the source posted, so a live test can
// assert the exact queries as well as the values they brought back.
//
// The port is fixed per file: the config naming it is parsed while vitest
// collects, before any hook could report a random one.
type t = {queries: array<JSON.t>, close: unit => promise<unit>}

let start: (int, string) => promise<t> = %raw(`async function (port, upstream) {
  const http = await import("node:http");
  const queries = [];
  const server = http.createServer(async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    if (req.method === "POST" && body.length > 0) {
      queries.push(JSON.parse(body.toString()));
    }
    const headers = { ...req.headers };
    // fetch would otherwise decode a compressed answer behind the client's back.
    for (const name of ["host", "content-length", "accept-encoding", "connection"]) delete headers[name];
    try {
      const answer = await fetch(upstream + req.url, {
        method: req.method,
        headers,
        body: body.length > 0 ? body : undefined,
      });
      const answerHeaders = {};
      answer.headers.forEach((value, name) => {
        if (!["content-encoding", "content-length", "transfer-encoding", "connection"].includes(name)) {
          answerHeaders[name] = value;
        }
      });
      res.writeHead(answer.status, answerHeaders);
      res.end(Buffer.from(await answer.arrayBuffer()));
    } catch (error) {
      res.writeHead(502);
      res.end(String(error));
    }
  });
  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));
  return { queries, close: () => new Promise((resolve) => server.close(() => resolve())) };
}`)

let serveDuringSuite = (~port, ~upstream) => {
  let proxy: ref<option<t>> = ref(None)
  Vitest.Async.beforeAll(async () => proxy := Some(await start(port, upstream)))
  Vitest.Async.afterAll(async () =>
    switch proxy.contents {
    | Some(started) => await started.close()
    | None => ()
    }
  )
  () => proxy.contents->Option.getOrThrow(~message="the recording proxy was never started")
}
