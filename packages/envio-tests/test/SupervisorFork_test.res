open Vitest

// What the fixture worker reports back in place of a metrics snapshot: the
// narrowing and the environment its supervisor handed it.
type fixtureReport = {
  isolatedChains: array<float>,
  maxConnections: string,
  logFile: string,
  startTime: Date.t,
}

let fixturePath = `${NodeJs.Process.cwd()}/test/helpers/fakeWorker.mjs`

let forkFixture = (~chainIds, ~maxConnections=2, ~workerIndex=0) =>
  Supervisor.fork(
    {chainIds: chainIds->Array.map(ChainId.fromInt), maxConnections},
    ~workerIndex,
    ~configJson=JSON.Object(Dict.fromArray([("name", JSON.String("indexer"))])),
    ~entryPath=fixturePath,
  )

describe("Supervisor.fork", () => {
  Async.it("Hands a worker its chains, its budget share, and its own log file", async t => {
    let running = forkFixture(~chainIds=[1, 137], ~maxConnections=3, ~workerIndex=1)

    let report = await Promise.make(
      (resolve, _) =>
        running.child->NodeJs.ChildProcess.onMessage(
          message =>
            switch message {
            | Worker.Snapshot({metrics}) =>
              resolve(metrics->(Utils.magic: Metrics.t => fixtureReport))
            },
        ),
    )
    running.child->NodeJs.ChildProcess.kill("SIGTERM")->ignore

    t.expect(report).toStrictEqual({
      isolatedChains: [1., 137.],
      maxConnections: "3",
      logFile: Supervisor.logFilePath(~workerIndex=1),
      // Proof the channel clones rather than stringifies: a JSON round trip
      // would have turned this into a string.
      startTime: Date.fromTime(1700000000000.),
    })
  })
})

describe("Supervisor.awaitExit", () => {
  let outcome = async group =>
    switch await group->Supervisor.awaitExit {
    | outcome => Ok(outcome)
    | exception _ => Error()
    }

  Async.it("Reports a group whose every worker finished on its own", async t => {
    NodeJs.Process.process.env->Dict.set("FAKE_WORKER", "succeed")
    let group: Supervisor.group = {
      running: [forkFixture(~chainIds=[1]), forkFixture(~chainIds=[137])],
      stopping: false,
    }

    t.expect(await outcome(group)).toStrictEqual(Ok(Supervisor.Finished))
  })

  Async.it(
    "Reports a group its supervisor took down as stopped, whatever the exit codes",
    async t => {
      NodeJs.Process.process.env->Dict.set("FAKE_WORKER", "linger")
      let group: Supervisor.group = {
        running: [forkFixture(~chainIds=[1]), forkFixture(~chainIds=[137])],
        stopping: false,
      }
      group->Supervisor.stop

      t.expect(await outcome(group)).toStrictEqual(Ok(Supervisor.Stopped))
    },
  )

  Async.it("Stops the group and fails the run when one worker dies", async t => {
    NodeJs.Process.process.env->Dict.set("FAKE_WORKER", "fail")
    let failing = forkFixture(~chainIds=[1])
    NodeJs.Process.process.env->Dict.set("FAKE_WORKER", "linger")
    let lingering = forkFixture(~chainIds=[137])
    let group: Supervisor.group = {running: [failing, lingering], stopping: false}

    // The survivor was taken down rather than left indexing half a schema.
    t.expect((await outcome(group), group.stopping, lingering.settled)).toStrictEqual((
      Error(),
      true,
      true,
    ))
  })
})
