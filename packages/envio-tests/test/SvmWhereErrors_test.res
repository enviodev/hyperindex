open Vitest

let configYaml = `
name: svm-where-errors
ecosystem: svm
chains:
  - id: solana
    start_block: 0
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Swapper
          program_id: 675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8
          instructions:
            - name: swap
              discriminator: "0x09"
              args:
                - { name: amountIn, type: u64 }
              accounts:
                - source
                - destination
            - name: bare
              discriminator: "0x0a"
            - name: wide
              discriminator: "0x0b"
              args:
                - { name: amountIn, type: u64 }
              accounts:
                - a0
                - a1
                - a2
                - a3
                - a4
                - a5
                - a6
                - a7
                - a8
                - a9
                - a10
`

let typeErrorOf = handlers =>
  try {
    InternalTestIndexer.fromUserApi(~schema=ApiTypesFixtures.schema, ~handlers, ~configYaml)->ignore
    "the type check to fail, but it succeeded"
  } catch {
  | JsExn(e) => e->JsExn.message->Option.getOr("an error with a message")
  }

describe("SVM onInstruction where types", () => {
  it("rejects an account name the instruction doesn't declare", t => {
    let actual = typeErrorOf(`
import { indexer } from "envio";

indexer.onInstruction(
  { program: "Swapper", instruction: "swap", where: { accounts: { missing: ["x"] } } },
  async () => {},
);
`)
    t.expect(actual->String.includes("missing")).toBe(true)
  })
})

InternalTestIndexer.fromUserApi(
  ~schema=ApiTypesFixtures.schema,
  ~configYaml,
  ~test=`
import { it, describe } from "vitest";
import { indexer } from "envio";

describe("SVM onInstruction where", () => {
  // An instruction that declares no args has nothing to decode, so selecting
  // \`args\` could only ever hand back an empty object.
  it("rejects selecting args on an instruction that declares none", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        { program: "Swapper", instruction: "bare", fields: { instruction: ["args"] } },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid "args" field in the fields.instruction option of the "bare" instruction on program "Swapper". The instruction declares no args in config.yaml, so there is nothing to decode. Remove "args" from the selection, or declare the instruction's args.\`,
    );
  });

  it("keeps args selectable on an instruction that declares them", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        { program: "Swapper", instruction: "swap", fields: { instruction: ["args"] } },
        async () => {},
      ),
    ).not.toThrow();
  });

  it("rejects a non-object where", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        { program: "Swapper", instruction: "swap", where: 1 as never },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid where configuration for the "swap" instruction on program "Swapper". Expected an object.\`,
    );
  });

  it("rejects an unknown where field", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        { program: "Swapper", instruction: "swap", where: { params: {} } as never },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid where configuration for the "swap" instruction on program "Swapper". Unknown field "params". Valid fields: "accounts", "isInner", "block".\`,
    );
  });

  it("rejects a non-boolean isInner", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        { program: "Swapper", instruction: "swap", where: { isInner: "yes" as never } },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid where configuration for the "swap" instruction on program "Swapper". The "isInner" filter must be a boolean.\`,
    );
  });

  it("rejects a non-object accounts filter", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        { program: "Swapper", instruction: "swap", where: { accounts: "x" as never } },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid where configuration for the "swap" instruction on program "Swapper". Expected "accounts" to be an object or an array of objects.\`,
    );
  });

  it("rejects a non-object entry inside an accounts array", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        { program: "Swapper", instruction: "swap", where: { accounts: ["x"] as never } },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid where configuration for the "swap" instruction on program "Swapper". Each entry in "accounts" must be an object.\`,
    );
  });

  it("rejects an unknown account name", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        {
          program: "Swapper",
          instruction: "swap",
          where: { accounts: { mint: ["So11111111111111111111111111111111111111112"] } as never },
        },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid where configuration for the "swap" instruction on program "Swapper". The instruction has no account named "mint" to filter on. Named accounts: "source", "destination".\`,
    );
  });

  it("rejects filtering an instruction with no named accounts", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        {
          program: "Swapper",
          instruction: "bare",
          where: { accounts: { source: ["So11111111111111111111111111111111111111112"] } as never },
        },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid where configuration for the "bare" instruction on program "Swapper". The instruction has no named accounts to filter on. Add \\\`accounts\\\` and \\\`args\\\` to it in config.yaml, or attach an IDL.\`,
    );
  });

  it("rejects an account past the tenth position", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        {
          program: "Swapper",
          instruction: "wide",
          where: { accounts: { a10: ["So11111111111111111111111111111111111111112"] } },
        },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid where configuration for the "wide" instruction on program "Swapper". Account "a10" is at position 10, and only the first 10 accounts of an instruction can be filtered.\`,
    );
  });

  it("rejects a filter value that is not a base58 pubkey", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        { program: "Swapper", instruction: "swap", where: { accounts: { source: ["not a pubkey"] } } },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid where configuration for the "swap" instruction on program "Swapper". The "source" filter value "not a pubkey" is not a base58 SVM pubkey.\`,
    );
  });

  it("rejects an empty pubkey list", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        { program: "Swapper", instruction: "swap", where: { accounts: { source: [] } } },
        async () => {},
      ),
    ).toThrowError(
      \`Invalid where configuration for the "swap" instruction on program "Swapper". The "source" filter must list at least one pubkey.\`,
    );
  });

  it("names the program when it is not configured", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        { program: "Swaper" as never, instruction: "swap", where: {} },
        async () => {},
      ),
    ).toThrowError(
      \`Program "Swaper" is not configured on any chain, so its handler for "swap" would never run. Add it to your config, or remove the registration. Configured programs: "Swapper".\`,
    );
  });

  it("names the instruction when it is not configured on the program", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        { program: "Swapper", instruction: "swep" as never, where: {} },
        async () => {},
      ),
    ).toThrowError(
      \`Instruction "swep" is not configured on program "Swapper", so its handler would never run. Add it to your config, or remove the registration. Configured instructions on "Swapper": "bare", "swap", "wide".\`,
    );
  });

  it("rejects a slot range that only onSlot supports", (t) => {
    t.expect(() =>
      indexer.onInstruction(
        {
          program: "Swapper",
          instruction: "swap",
          where: { block: { slot: { _every: 10 } } as never },
        },
        async () => {},
      ),
    ).toThrowError("use \\\`indexer.onSlot\\\` for \\\`_lte\\\` or \\\`_every\\\`");
  });
});
`,
)->ignore
