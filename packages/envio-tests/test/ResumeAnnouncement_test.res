open Vitest

// The supervisor says it once for the whole run, so a worker it forked has
// nothing to add. Every other process resuming is somebody's only window onto
// it, `envio start --chain` included.

let scenario = Scenario.make(
  ~supervised=false,
  ~configYaml=`
name: resume-announcement
chains:
  - id: 1337
    rpc:
      url: https://rpc.example.test
      for: sync
    start_block: 1
    contracts:
      - name: Gravatar
        address: "0x2B2f78c5BF6D9C12Ee1225D5F374aa91204580c3"
        events:
          - event: "TestEvent()"
`,
  ~schema=`
type Tally {
  id: ID!
}
`,
)

let resumeLines = (indexer: IndexerRunner.t) =>
  indexer.logs()
  ->Array.map(entry => entry.msg)
  ->Array.filter(msg => msg->String.includes("esum"))

describe("Announcing a resume", () => {
  scenario->Scenario.it(
    "is quiet for a forked worker, and not for anyone else",
    ~sources=[{chain: 1337}],
    ~captureLogs=true,
    async (~t, ~indexer, ~source) => {
      source(1337).setAutoHeight(100)
      let beforeResuming = indexer->resumeLines
      let worker = await indexer.restart(~asWorker=true, ())
      let afterWorker = worker->resumeLines
      let standalone = await worker.restart()

      t.expect((
        afterWorker->Array.slice(~start=beforeResuming->Array.length),
        standalone->resumeLines->Array.slice(~start=afterWorker->Array.length),
      )).toEqual((
        [],
        [
          "Found existing indexer storage. Resuming indexing state...",
          "Successfully resumed indexing state! Continuing from the last checkpoint.",
        ],
      ))
    },
  )
})
