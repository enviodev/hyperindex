open Vitest

// What the fixture worker reports back in place of a metrics snapshot: the
// environment its supervisor handed it, which is the whole of what a worker is
// told before it starts.
type fixtureReport = {
  workerConfig: string,
  maxConnections: string,
  bufferSize: string,
  objectsTarget: string,
  logFile: string,
  startTime: Date.t,
  hasArrivedAtHead: bool,
}

let fixturePath = `${NodeJs.Process.cwd()}/test/helpers/fakeWorker.mjs`

let forkFixture = (
  ~chainIds,
  ~maxConnections=2,
  ~workerIndex=0,
  ~workerCount=2,
  ~holdRealtime=false,
  ~isDev=false,
  ~pipeOutput=false,
  ~onOutput=?,
  ~onErrorOutput=?,
) =>
  Supervisor.fork(
    {chainIds: chainIds->Array.map(ChainId.fromInt), maxConnections},
    ~workerIndex,
    ~workerCount,
    ~holdRealtime,
    ~isDev,
    ~entryPath=fixturePath,
    ~pipeOutput,
    ~onOutput?,
    ~onErrorOutput?,
  )

describe("Supervisor.fork", () => {
  Async.it("Hands a worker its chains, its budget share, and its own log file", async t => {
    let running = forkFixture(
      ~chainIds=[1, 137],
      ~maxConnections=3,
      ~workerIndex=1,
      ~workerCount=4,
      ~holdRealtime=true,
      ~isDev=true,
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
      // before it can load its own config, so it can't arrive as a message. The
      // project's files say nothing about which command started the run, which
      // is why `isDev` is among them.
      workerConfig: `{"chainIds":[1,137],"holdRealtime":true,"isDev":true}`,
      maxConnections: "3",
      // The run's memory budgets are the whole indexer's, so a worker gets a
      // share rather than the whole of each.
      bufferSize: (CrossChainState.calculateTargetBufferSize() / 4)->Int.toString,
      objectsTarget: (Env.inMemoryObjectsTarget->Float.toInt / 4)->Int.toString,
      logFile: Supervisor.logFilePath(~workerIndex=1),
      // Proof the channel clones rather than stringifies: a JSON round trip
      // would have turned this into a string.
      startTime: Date.fromTime(1700000000000.),
      hasArrivedAtHead: false,
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
      releaseCheck: None,
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
        releaseCheck: None,
      }
      group->Supervisor.stop

      t.expect(await outcome(group)).toStrictEqual(Ok(Supervisor.Stopped))
    },
  )

  // A process manager that signals the whole group reaches the workers itself,
  // so they exit on a SIGTERM the supervisor has not passed on and may not even
  // have handled yet. Reading that as a worker dying would fail every clean
  // shutdown under systemd's default kill mode.
  Async.it("Takes a worker signalled from outside as the run being stopped", async t => {
    NodeJs.Process.process.env->Dict.set("FAKE_WORKER", "linger")
    let signalled = forkFixture(~chainIds=[1])
    let sibling = forkFixture(~chainIds=[137])
    let group: Supervisor.group = {
      running: [signalled, sibling],
      stopping: false,
      releaseCheck: None,
    }
    let ended = outcome(group)
    signalled.child->NodeJs.ChildProcess.kill("SIGTERM")->ignore

    // The sibling still went down with it: one worker short leaves its chains
    // unindexed.
    t.expect((await ended, group.stopping)).toStrictEqual((Ok(Supervisor.Stopped), true))
  })

  Async.it("Stops the group and fails the run when one worker dies", async t => {
    NodeJs.Process.process.env->Dict.set("FAKE_WORKER", "fail")
    let failing = forkFixture(~chainIds=[1])
    NodeJs.Process.process.env->Dict.set("FAKE_WORKER", "linger")
    let lingering = forkFixture(~chainIds=[137])
    let group: Supervisor.group = {
      running: [failing, lingering],
      stopping: false,
      releaseCheck: None,
    }

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
  // draws: ink only knows about the lines its own process logs. Each line keeps
  // the stream it was written to, so redirecting the run's stderr still catches
  // what its workers wrote there. Sorted, since stdout and stderr are two pipes
  // and neither waits for the other.
  Async.it("Hands the supervisor every line a worker writes, on its own stream", async t => {
    NodeJs.Process.process.env->Dict.set("FAKE_WORKER", "print")
    let lines = []
    let group: Supervisor.group = {
      running: [
        forkFixture(
          ~chainIds=[1],
          ~pipeOutput=true,
          ~onOutput=line => lines->Array.push(("stdout", line))->ignore,
          ~onErrorOutput=line => lines->Array.push(("stderr", line))->ignore,
        ),
      ],
      stopping: false,
      releaseCheck: None,
    }
    let _ = await group->Supervisor.awaitExit

    t.expect(
      lines->Array.toSorted(((_, a), (_, b)) => String.compare(a, b)),
    ).toStrictEqual([
      ("stdout", "first line"),
      ("stderr", "from stderr"),
      ("stdout", "second line"),
    ])
  })
})

describe("Supervisor.isRunAtHead", () => {
  let untilReported = async (running: array<Supervisor.running>) => {
    let rec until = async deadline =>
      if !(running->Array.every(r => r.snapshot->Option.isSome)) && Date.now() < deadline {
        await Utils.delay(10)
        await until(deadline)
      }
    await until(Date.now() +. 3000.)
  }

  let untilGone = async (r: Supervisor.running) => {
    let rec until = async deadline =>
      if r.child->NodeJs.ChildProcess.connected && Date.now() < deadline {
        await Utils.delay(10)
        await until(deadline)
      }
    await until(Date.now() +. 3000.)
  }

  let arrivingFixture = (~chainIds, ~mode) => {
    NodeJs.Process.process.env->Dict.set("FAKE_WORKER", mode)
    NodeJs.Process.process.env->Dict.set("FAKE_WORKER_ARRIVED", "1")
    forkFixture(~chainIds)
  }

  Async.it("Holds the run until every worker has arrived", async t => {
    let arrived = arrivingFixture(~chainIds=[1], ~mode="linger")
    NodeJs.Process.process.env->Dict.set("FAKE_WORKER_ARRIVED", "0")
    let backfilling = forkFixture(~chainIds=[137])
    let group: Supervisor.group = {
      running: [arrived, backfilling],
      stopping: false,
      releaseCheck: None,
    }
    await untilReported(group.running)

    // One worker still backfilling speaks for the whole run, and a worker that
    // has yet to report drives chains nobody can see.
    let readings = (
      group.running->Supervisor.isRunAtHead,
      [arrived]->Supervisor.isRunAtHead,
      []->Supervisor.isRunAtHead,
    )
    group->Supervisor.stop
    let _ = await group->Supervisor.awaitExit

    t.expect(readings).toStrictEqual((false, true, false))
  })

  // Every worker said it had arrived, and then one of them was gone. Its
  // snapshot outlives it, so a run read from the snapshots alone still looks
  // whole, and the release would be sent into a channel Node had already
  // closed — which comes back as the error a supervisor reports as a worker
  // failing to start.
  Async.it("Never releases a run a worker has left", async t => {
    let lingering = arrivingFixture(~chainIds=[1], ~mode="linger")
    let leaving = arrivingFixture(~chainIds=[137], ~mode="succeed-later")
    let group: Supervisor.group = {
      running: [lingering, leaving],
      stopping: false,
      releaseCheck: None,
    }
    await untilReported(group.running)
    await untilGone(leaving)

    let readings = (
      group.running->Supervisor.isRunAtHead,
      // Both snapshots are still there, and both of them still say arrived.
      group.running->Array.filterMap(r => r.snapshot)->Array.length,
    )
    group->Supervisor.stop
    await untilGone(lingering)

    t.expect(readings).toStrictEqual((false, 2))
  })
})
