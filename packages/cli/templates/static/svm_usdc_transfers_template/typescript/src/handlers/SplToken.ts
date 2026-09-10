/*
 * Please refer to https://docs.envio.dev for a thorough guide on all Envio indexer features
 */
import { indexer, type SvmInstruction, type Transfer } from "envio";

/** USD Coin. Swap in any SPL mint to follow that token instead. */
const MINT = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";

/** Only the fields listed here are fetched, so keep the list to what the
 *  handlers read — every extra field is bandwidth on every instruction. */
const fields = {
  instruction: ["accounts", "args", "path"],
  transaction: ["signature", "transactionIndex"],
  accountActivity: ["token.mint"],
  block: ["time"],
} as const;

type TokenTransfer =
  | SvmInstruction<typeof fields, "SplToken", "transfer">
  | SvmInstruction<typeof fields, "SplToken", "transferChecked">;

/** `path` locates the instruction inside its transaction's CPI tree, so
 *  (slot, transaction, path) is unique for top-level and inner calls alike. */
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

// `transferChecked` names the mint in its account list, so `where` narrows the
// stream server-side and nothing arrives that has to be thrown away.
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

// Plain `transfer` carries no mint — its accounts are (source, destination,
// authority) — so which token moved is only knowable from the transaction's
// token balances, which `fields.accountActivity` joins onto the named accounts.
// Either account answers it, since SPL Token rejects a transfer between
// different mints, and reading only the source would lose the transfers whose
// source the transaction itself opened: an account with no balance before the
// transaction is absent from the records.
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
