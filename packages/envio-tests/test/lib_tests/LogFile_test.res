open Vitest

describe("LogFile.messages", () => {
  Async.it("Skips a line still being written", async t => {
    let path = `${NodeJs.Process.cwd()}/lib/envio-partial-line-${Date.now()->Float.toString}.log`
    await NodeJs.Fs.Promises.writeFile(
      ~filepath=NodeJs.Path.resolve([path]),
      ~content=`{"level":30,"msg":"first"}\n{"level":30,"ms`,
    )

    t.expect(await LogFile.messages(path)).toEqual(["first"])
  })
})
