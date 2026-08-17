open Vitest

// Program-less registrations: `indexer.onRawInstruction` selects instructions
// by `where` alone, with no program declared in config.yaml. Registered through
// a real handler module, which is the only path they take in a project.

let programId = "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8"

let {config}: InternalTestIndexer.parsed = InternalTestIndexer.fromUserApi(
  ~schema=ApiTypesFixtures.schema,
  ~configYaml=`
name: svm-raw-instruction
ecosystem: svm
chains:
  - start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Swapper
          program_id: ${programId}
          instructions:
            - name: swap
              discriminator: "0x09"
              args:
                - { name: amountIn, type: u64 }
              accounts:
                - source
`,
  ~handlers=`
import { indexer } from "envio";

const programId = "${programId}";

// A config-declared registration and a raw one selecting the same instruction.
// Both are dispatched — the raw one is not a substitute for the named one.
indexer.onInstruction({ program: "Swapper", instruction: "swap" }, async () => {});

indexer.onRawInstruction(
  { where: { programId, discriminator: "0x09" } },
  async ({ instruction }) => {
    instruction.data;
  },
);

// Same selector as the registration above: still its own registration, because
// identity comes from the call, not from the selector.
indexer.onRawInstruction({ where: { programId, discriminator: "0x09" } }, async () => {});

// A different selector, and the options a raw registration has no config entry
// to inherit: its own field selection and logs.
indexer.onRawInstruction(
  {
    where: {
      programId,
      discriminator: "0x0a",
      isInner: false,
      accountFilters: [{ position: 0, values: [programId] }],
    },
    fields: { transaction: ["signature"], block: ["parentSlot"] },
    includeLogs: true,
  },
  async () => {},
);
`,
  ~test=`
import { describe, it } from "vitest";
import { indexer } from "envio";

const programId = "${programId}";

// Registration is still open here — the suite never builds a test indexer — so
// a rejected registration throws out of \`onRawInstruction\` where it can be
// asserted. A raw registration has no contract or event name, so every message
// has to name the selector the user wrote instead.
describe("a rejected raw registration", () => {
  it("rejects a discriminator that isn't 1, 2, 4 or 8 bytes", (t) => {
    t.expect(() =>
      indexer.onRawInstruction({ where: { programId, discriminator: "0x0102ff" } }, async () => {}),
    ).toThrowError(
      \`\\\`indexer.onRawInstruction\\\` \\\`where.discriminator\\\` must be a hex value of 1, 2, 4 or 8 bytes ("0x" optional), but got "0x0102ff".\`,
    );
  });

  it("requires a selector at all", (t) => {
    t.expect(() => indexer.onRawInstruction({} as never, async () => {})).toThrowError(
      \`\\\`indexer.onRawInstruction\\\` requires a \\\`where\\\` selector describing the instructions to index.\`,
    );
  });

  it("rejects an unknown key in the selector", (t) => {
    t.expect(() =>
      indexer.onRawInstruction(
        { where: { programId, discriminatr: "0x09" } as never },
        async () => {},
      ),
    ).toThrowError(\`\\\`indexer.onRawInstruction\\\` \\\`where\\\` is invalid:\`);
  });

  it("names the selector, not the ordinal, when a field is invalid", (t) => {
    t.expect(() =>
      indexer.onRawInstruction(
        {
          where: { programId, discriminator: "0x09" },
          fields: { block: ["notAField" as never] },
        },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid "notAField" field in the fields.block option of the raw registration for where { programId: "\${programId}", discriminator: "0x09" }. Valid block fields: slot, time, hash, height, parentSlot, parentHash.\`,
    );
  });
});
`,
)

let chainRegistrations = () => {
  let registrations: HandlerRegister.chainRegistrations =
    HandlerRegister.finishRegistration(~config)
    ->Utils.Dict.dangerouslyGetNonOption("0")
    ->Option.getOrThrow
  registrations.onEventRegistrations
}

describe("SVM raw instruction registrations", () => {
  it("keeps every raw registration separate from the named one and from each other", t => {
    // Two raw registrations share a selector (ordinals 0 and 1) and the third
    // selects something else; none of them merges, and none of them takes the
    // identity of the config-declared instruction they overlap with.
    t.expect(
      chainRegistrations()->Array.map(
        reg => (Internal.identityKey(reg.eventConfig.identity), reg.index, reg.isWildcard),
      ),
    ).toEqual([
      ("Swapper.swap", 0, false),
      ("raw:svm:0", 1, true),
      ("raw:svm:1", 2, true),
      ("raw:svm:2", 3, true),
    ])
  })

  it("synthesizes the event config from the selector", t => {
    t.expect(
      chainRegistrations()
      ->(Utils.magic: array<Internal.onEventRegistration> => array<Internal.svmOnEventRegistration>)
      ->SvmHyperSyncClient.Registration.fromOnEventRegistrations
      ->Array.map(
        input => (
          input.contractName,
          input.instructionName,
          input.programId,
          input.discriminator,
          input.discriminatorByteLen,
          input.isInner,
          input.accountFilters,
          input.includeLogs,
          input.transactionFields,
          input.blockFields,
        ),
      ),
    ).toEqual([
      (
        "Swapper",
        "swap",
        programId,
        Some("0x09"),
        1,
        None,
        [],
        false,
        [],
        ["slot", "time", "hash"],
      ),
      (programId, "raw", programId, Some("0x09"), 1, None, [], false, [], ["slot", "time", "hash"]),
      (programId, "raw", programId, Some("0x09"), 1, None, [], false, [], ["slot", "time", "hash"]),
      (
        programId,
        "raw",
        programId,
        Some("0x0a"),
        1,
        Some(false),
        [[{position: 0, values: [programId]}]],
        true,
        ["signature"],
        ["slot", "time", "hash", "parentSlot"],
      ),
    ])
  })
})
