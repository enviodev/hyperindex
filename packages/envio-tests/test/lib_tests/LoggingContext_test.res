open Vitest

// Reads what pino actually wrote: a duplicated field survives JSON parsing
// (the last one wins), so the raw line is the only place it shows.
let occurrences = (line, ~field) =>
  line->String.split(`"${field}"`)->Array.length - 1

// The file is written by pino's transport worker, so it lands a moment later.
let readWhenWritten = async path => {
  let deadline = Date.now() +. 3000.
  let read = async () =>
    switch await NodeJs.Fs.Promises.readFile(
      ~filepath=NodeJs.Path.resolve([path]),
      ~encoding=Utf8,
    ) {
    | contents => contents
    | exception _ => ""
    }
  let rec until = async () =>
    switch await read() {
    | "" if Date.now() < deadline =>
      await Utils.delay(50)
      await until()
    | contents => contents
    }
  await until()
}

describe("Logging.setContext", () => {
  Async.it("Names the chain once, whoever else on the line names it", async t => {
    let path = `${NodeJs.Process.cwd()}/lib/envio-logging-context-${Date.now()
      ->Float.toString}.log`
    Logging.setLogger(
      Logging.makeLogger(
        ~logStrategy=FileOnly,
        ~logFilePath=path,
        ~defaultFileLogLevel=#info,
        ~userLogLevel=#info,
      ),
    )
    Logging.setContext(Dict.fromArray([("chainId", JSON.Number(137.))]))

    Logging.info("a line with no chain in hand")
    Logging.createChild(~params={"chainId": 137, "source": "hypersync"})->Logging.childInfo({
      "msg": "a line from a chain-scoped logger",
    })

    let lines =
      (await readWhenWritten(path))
      ->String.trim
      ->String.split("\n")

    t.expect(lines->Array.map(line => occurrences(line, ~field="chainId"))).toStrictEqual([1, 1])
  })
})
