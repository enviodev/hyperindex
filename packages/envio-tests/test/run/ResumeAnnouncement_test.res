open Vitest

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
  indexer.infoAndAboveLogs()
  ->Array.map(entry => entry.msg)
  ->Array.filter(msg =>
    msg->String.toLowerCase->String.includes("resum") ||
      msg->String.includes("existing indexer storage")
  )

describe("Announcing a resume", () => {
  // A supervisor resumes no chain: each worker resumes and announces its own,
  // which is the process a refusal would come from.
  scenario->Scenario.it(
    "is the resuming process's to announce, not its supervisor's",
    ~sources=[{chain: 1337}],
    async (~t, ~indexer, ~source) => {
      source(1337).setAutoHeight(100)
      let beforeResuming = indexer->resumeLines
      let resumed = await indexer.restart()
      let supervisorLogger = Logger.makeInMemory()
      let storage = Storage.makeStorageFromEnv(
        ~config=scenario.config,
        ~logger=supervisorLogger,
        ~pgSchema=resumed.pgSchema,
        ~isHasuraEnabled=false,
      )
      let _ = await storage->Persistence.initForSupervisor(
        ~logger=supervisorLogger,
        ~config=scenario.config,
        ~reset=false,
      )
      await storage.close()

      t.expect((
        resumed->resumeLines->Array.slice(~start=beforeResuming->Array.length),
        supervisorLogger
        ->Logger.inMemoryLines
        ->Array.filterMap(
          line =>
            switch line->Dict.get("msg") {
            | Some(String(msg)) if msg->String.toLowerCase->String.includes("resum") => Some(msg)
            | _ => None
            },
        ),
      )).toEqual((
        [
          "Found existing indexer storage.",
          "Successfully resumed indexing state! Continuing from the last checkpoint.",
        ],
        [],
      ))
    },
  )
})
