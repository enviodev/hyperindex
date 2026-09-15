/*
 * Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features
 */
import { indexer, type SvmInstruction, type Transfer } from "envio";

/** USD Coin. Swap in any SPL mint to follow that token instead. */
const MINT = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";

/** Only the listed fields are fetched, so keep it to what the handlers read. */
const fields = {
  instruction: ["accounts", "args", "path"],
  transaction: ["signature", "transactionIndex"],
  accountActivity: ["token.mint"],
  block: ["time"],
} as const;

type TokenTransfer =
  | SvmInstruction<typeof fields, "SplToken", "transfer">
  | SvmInstruction<typeof fields, "SplToken", "transferChecked">;

const toTransfer = (instruction: TokenTransfer, checked: boolean): Transfer => ({
  id: `${instruction.block.slot}-${instruction.transaction.transactionIndex}-${instruction.path.join(".")}`,
  amount: instruction.args.amount,
  source: instruction.accounts.source.address,
  destination: instruction.accounts.destination.address,
  signer: instruction.accounts.authority.address,
  txSignature: instruction.transaction.signature,
  slot: instruction.block.slot,
  timestamp: instruction.block.time,
  checked,
});

// `transferChecked` names its mint, so `where` filters server-side.
indexer.onInstruction(
  {
    program: "SplToken",
    instruction: "transferChecked",
    fields,
    where: { accounts: { mint: MINT } },
  },
  async ({ instruction, context }) => {
    context.Transfer.set(toTransfer(instruction, true));
  },
);

// Plain `transfer` does not, so the mint comes from the token balances
// `fields.accountActivity` joins onto the accounts. Either one answers it, and a
// source the transaction itself opened has no balance to report — hence both.
indexer.onInstruction(
  { program: "SplToken", instruction: "transfer", fields },
  async ({ instruction, context }) => {
    const { source, destination } = instruction.accounts;
    if (source.activity?.token?.mint !== MINT && destination.activity?.token?.mint !== MINT) {
      return;
    }
    context.Transfer.set(toTransfer(instruction, false));
  },
);
