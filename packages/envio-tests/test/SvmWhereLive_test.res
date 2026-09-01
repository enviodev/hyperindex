// Live test against solana.hypersync.xyz over a pinned slot window, driven
// through the user API: real config, real handlers, the real source and
// routing. Covers what the mocked tests can't — that a `where` resolved at
// registration reaches the server query and comes back narrowed.
//
// The two filters are checked by invariants rather than fixed counts, so the
// window's contents can shift without rewriting expectations: Raydium's AMM
// authority is a constant PDA present on every v4 swap, and `isInner` true
// and false partition the unfiltered set.

// The source reads the token from the environment itself; required here so a
// missing one fails loudly instead of silently querying unauthenticated.
let _apiToken =
  Env.envioApiToken->Option.getOrThrow(
    ~message="ENVIO_API_TOKEN env var must be set to run the live SVM where test",
  )

let raydiumAuthority = "5Q544fKrFoe6tsEbD7S8EmxGTJYAKtTVhAW5Q5pge4j1"
let notTheAuthority = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"

let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: svm-where-live
ecosystem: svm
chains:
  - id: solana
    start_block: 420650000
    end_block: 420650200
    experimental:
      hypersync_config:
        url: https://solana.hypersync.xyz
      programs:
        - name: Raydium
          program_id: 675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8
          instructions:
            - name: swap
              discriminator: "0x09"
              args:
                - { name: amountIn, type: u64 }
                - { name: minAmountOut, type: u64 }
              accounts:
                - tokenProgram
                - amm
                - ammAuthority
                - ammOpenOrders
                - ammTargetOrders
                - poolCoinTokenAccount
                - poolPcTokenAccount
                - serumProgram
                - serumMarket
                - serumBids
                - serumAsks
                - serumEventQueue
                - serumCoinVaultAccount
                - serumPcVaultAccount
                - serumVaultSigner
                - userSourceTokenAccount
                - userDestTokenAccount
                - userSourceOwner
`,
  ~schema=`
type Hit {
  id: ID!
  tag: String!
  ammAuthority: String!
  isInner: Boolean!
  amountIn: BigInt!
  amountInIsBigint: Boolean!
}
`,
  ~handlers=`
import { indexer, type SvmOnInstructionHandler } from "envio";

const fields = {
  instruction: ["accounts", "isInner", "path", "args"],
  transaction: ["signature"],
} as const;

const record =
  (tag: string): SvmOnInstructionHandler<typeof fields, "Raydium", "swap"> =>
  async ({ instruction, context }) => {
    context.Hit.set({
      id: \`\${tag}:\${instruction.transaction.signature}:\${instruction.path.join(".")}\`,
      tag,
      ammAuthority: instruction.accounts.ammAuthority.address,
      isInner: instruction.isInner,
      amountIn: instruction.args.amountIn,
      amountInIsBigint: typeof instruction.args.amountIn === "bigint",
    });
  };

indexer.onInstruction({ program: "Raydium", instruction: "swap", fields }, record("all"));

indexer.onInstruction(
  {
    program: "Raydium",
    instruction: "swap",
    fields,
    where: { accounts: { ammAuthority: "${raydiumAuthority}" } },
  },
  record("authority"),
);

indexer.onInstruction(
  {
    program: "Raydium",
    instruction: "swap",
    fields,
    where: { accounts: { ammAuthority: "${notTheAuthority}" } },
  },
  record("wrongAuthority"),
);

indexer.onInstruction(
  { program: "Raydium", instruction: "swap", fields, where: { isInner: true } },
  record("inner"),
);

indexer.onInstruction(
  { program: "Raydium", instruction: "swap", fields, where: { isInner: false } },
  record("outer"),
);
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type Hit } from "envio";

describe("SVM onInstruction where (live)", () => {
  it(
    "narrows a real HyperSync range by account and by inner/outer",
    async (t) => {
      const indexer = createTestIndexer();
      await indexer.process({ chains: { 7565164: { endBlock: 420650200 } } });

      const hits: Hit[] = await indexer.Hit.getAll();
      const tagged = (tag: string) => hits.filter((hit) => hit.tag === tag);
      const all = tagged("all");
      const authority = tagged("authority");
      const inner = tagged("inner");
      const outer = tagged("outer");

      t.expect({
        windowHasSwaps: all.length > 0,
        authorityMatchesEverySwap: authority.length === all.length,
        wrongAuthorityMatchesNothing: tagged("wrongAuthority").length === 0,
        innerAndOuterPartitionTheSwaps: inner.length + outer.length === all.length,
        windowHasBothInnerAndOuterSwaps: inner.length > 0 && outer.length > 0,
        authorityHitsCarryTheAuthority: authority.every(
          (hit) => hit.ammAuthority === "${raydiumAuthority}",
        ),
        innerHitsAreInner: inner.every((hit) => hit.isInner),
        outerHitsAreOuter: outer.every((hit) => !hit.isInner),
        argsDecodeAsBigints: all.every((hit) => hit.amountInIsBigint),
        someSwapMovesTokens: all.some((hit) => hit.amountIn > 0n),
      }).toEqual({
        windowHasSwaps: true,
        authorityMatchesEverySwap: true,
        wrongAuthorityMatchesNothing: true,
        innerAndOuterPartitionTheSwaps: true,
        windowHasBothInnerAndOuterSwaps: true,
        authorityHitsCarryTheAuthority: true,
        innerHitsAreInner: true,
        outerHitsAreOuter: true,
        argsDecodeAsBigints: true,
        someSwapMovesTokens: true,
      });
    },
    300_000,
  );
});
`,
)
