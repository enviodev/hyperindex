// Live test against solana.hypersync.xyz over a pinned slot window holding
// exactly one call of the IslandDAO events program, which HyperSync returns
// without any instruction-scoped logs. A handler that selects `fields.log`
// must still get `instruction.logs` as an array.

let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live SVM logs test",
  )

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: svm-logs-live
ecosystem: svm
chains:
  - id: solana
    start_slot: 458404000
    end_slot: 458404200
programs:
  - name: IslandEvents
    program_id: tabiZjsKYe5rs8fMM7FonZaw3pVBpiWMosB25eN6RrU
    instructions:
      - name: register
        discriminator: "0x04"
`,
  ~schema=`
type Call {
  id: ID!
  logsIsArray: Boolean!
  logCount: Int!
}
`,
  ~handlers=`
import { indexer } from "envio";

indexer.onInstruction(
  {
    program: "IslandEvents",
    instruction: "register",
    fields: { instruction: ["path"], transaction: ["signature"], log: ["kind", "message"] },
  },
  async ({ instruction, context }) => {
    context.Call.set({
      id: \`\${instruction.transaction.signature}:\${instruction.path.join(".")}\`,
      logsIsArray: Array.isArray(instruction.logs),
      logCount: Array.isArray(instruction.logs) ? instruction.logs.length : -1,
    });
  },
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer } from "envio";

describe("SVM instruction logs (live)", () => {
  it(
    "hands an instruction without logs an empty array",
    async (t) => {
      const indexer = createTestIndexer();
      await indexer.process({ chains: { 7565164: { endBlock: 458404200 } } });

      t.expect(await indexer.Call.getAll()).toEqual([
        {
          id: "2McaLcEbzWHX2YWcYusA9g2C7YnhXpWnc7FUbyUshcMvoVes7GRgLSu5SunrUtP1GbRNWHHBgkg6Ftr89wMLL3MG:2",
          logsIsArray: true,
          logCount: 0,
        },
      ]);
    },
    300_000,
  );
});
`,
)
