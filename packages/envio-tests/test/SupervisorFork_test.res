open Vitest

// What the fixture worker reports back in place of a metrics snapshot: the
// environment its supervisor handed it, which is the whole of what a worker is
// told before it starts.
type fixtureReport = {
  workerConfig: string,
  maxConnections: string,
  logFile: string,
  startTime: Date.t,
}

let fixturePath = `${NodeJs.Process.cwd()}/test/helpers/fakeWorker.mjs`

let forkFixture = (
  ~chainIds,
  ~maxConnections=2,
  ~workerIndex=0,
  ~holdRealtime=false,
  ~pipeOutput=false,
  ~onOutput=?,
) =>
  Supervisor.fork(
    {chainIds: chainIds->Array.map(ChainId.fromInt), maxConnections},
    ~workerIndex,
    ~holdRealtime,
    ~entryPath=fixturePath,
    ~pipeOutput,
    ~onOutput?,
  )

describe("Supervisor.fork", () => {
  Async.it("Hands a worker its chains, its budget share, and its own log file", async t => {
    let running = forkFixture(
      ~chainIds=[1, 137],
      ~maxConnections=3,
      ~workerIndex=1,
      ~holdRealtime=true,
    )

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
      // Everything the supervisor decided, in the environment: a worker needs it
      // before it can load its own config, so it can't arrive as a message.
      workerConfig: `{"chainIds":[1,137],"holdRealtime":true}`,
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

describe("Supervisor.readLines", () => {
  it("Holds a half line until the chunk that finishes it, or the stream ends", t => {
    let lines = []
    let (read, flush) = Supervisor.readLines(~onLine=line => lines->Array.push(line)->ignore)
    ["a line\nand ", "half of ", "another\nlast\n", "no newline here"]->Array.forEach(read)
    flush()
    // Nothing is left to flush twice.
    flush()

    t.expect(lines).toStrictEqual([
      "a line",
      "and half of another",
      "last",
      "no newline here",
    ])
  })
})

describe("Supervisor.fork output", () => {
  // A worker writing straight to the terminal tears the frame its supervisor
  // draws: ink only knows about the lines its own process logs. Sorted, since
  // stdout and stderr are two pipes and neither waits for the other.
  Async.it("Hands the supervisor every line a worker writes, whole", async t => {
    NodeJs.Process.process.env->Dict.set("FAKE_WORKER", "print")
    let lines = []
    let group: Supervisor.group = {
      running: [
        forkFixture(
          ~chainIds=[1],
          ~pipeOutput=true,
          ~onOutput=line => lines->Array.push(line)->ignore,
        ),
      ],
      stopping: false,
    }
    let _ = await group->Supervisor.awaitExit

    t.expect(lines->Array.toSorted(String.compare)).toStrictEqual([
      "first line",
      "from stderr",
      "second line",
    ])
  })
})
