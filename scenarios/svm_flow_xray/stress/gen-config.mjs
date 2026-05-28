// Emits a stress config YAML for one matrix cell, to stress/.generated/.
//
//   node gen-config.mjs <programSet> <windowSlots> <tokenBalances> <outPath>
//
//   programSet    "defi" | "defi+hf"   (hf = SplToken + System)
//   windowSlots   integer (end_block = START + windowSlots)
//   tokenBalances "true" | "false"
//
// When tokenBalances=false we still request transaction_fields so the handler
// has a tx signature to key writes on; only the per-tx token_balance fan-out is
// dropped. That isolates Variable C (token_balance fan-out) from the constant
// InstructionNode + FlowTx writes.
//
// Run root is the stress/ dir (cwd), made self-contained via symlinks
// (node_modules, idls, schema.graphql, .envio) so its src/handlers/ -- which
// registers SplToken + System -- is what the handler auto-loader globs. The
// config `handlers:` field is intentionally omitted: it is dropped for SVM in
// to_public_config_json, so the loader always uses the default src/handlers.
//
// Path resolution is split in the Rust core: `schema:` resolves relative to the
// CONFIG FILE's directory (this file lives in stress/.generated/, so ../ =
// stress/), while `idl:` resolves relative to the project root (= cwd =
// stress/).

import { writeFileSync } from "node:fs";

const START = 420_650_000;

const [, , programSet, windowSlotsStr, tokenBalancesStr, outPath] = process.argv;
if (!programSet || !windowSlotsStr || !tokenBalancesStr || !outPath) {
  console.error("usage: gen-config.mjs <defi|defi+hf> <windowSlots> <true|false> <outPath>");
  process.exit(2);
}
const windowSlots = Number(windowSlotsStr);
const endBlock = START + windowSlots;
const tokenBalances = tokenBalancesStr === "true";

// field_selection block shared by every instruction.
const fsLines = tokenBalances
  ? ["            field_selection:", "              token_balance_fields: true"]
  : ["            field_selection:", "              transaction_fields: true"];

const ix = (name, disc, body = []) =>
  ["          - name: " + name, '            discriminator: "' + disc + '"', ...body, ...fsLines];

const defiPrograms = [
  ["Jupiter", "JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4", "        idl: idls/jupiter.json", [
    ...ix("route", "0xe517cb977ae3ad2a"),
    ...ix("sharedAccountsRoute", "0xc1209b3341d69c81"),
  ]],
  ["Kamino", "KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD", "        idl: idls/kamino.json", [
    ...ix("depositReserveLiquidityAndObligationCollateral", "0x81c70402de271a2e"),
    ...ix("borrowObligationLiquidity", "0x797f12cc49f5e141"),
    ...ix("repayObligationLiquidity", "0x91b20de14cf09348"),
    ...ix("withdrawObligationCollateralAndRedeemReserveCollateral", "0x4b5d5ddc2296dac4"),
  ]],
  ["Drift", "dRiftyHA39MWEi3m9aunc5MzRF1JYuBsbn6VPcozatL", "        idl: idls/drift.json", [
    ...ix("placePerpOrder", "0x45a15dca787e4cb9"),
    ...ix("fillPerpOrder", "0x0dbcf86786d96af0"),
    ...ix("liquidatePerp", "0x4b2377f7bf128b02"),
    ...ix("liquidateSpot", "0x6b00802923e5fb12"),
    ...ix("settlePnl", "0x2b3dea2d0f5f9899"),
  ]],
  ["Raydium", "675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8", null, [
    ...ix("swap", "0x09", [
      "            args:",
      "              - { name: amountIn, type: u64 }",
      "              - { name: minAmountOut, type: u64 }",
      "            accounts: [tokenProgram, amm, ammAuthority, ammOpenOrders, ammTargetOrders, poolCoinTokenAccount, poolPcTokenAccount, serumProgram, serumMarket, serumBids, serumAsks, serumEventQueue, serumCoinVaultAccount, serumPcVaultAccount, serumVaultSigner, userSourceTokenAccount, userDestTokenAccount, userSourceOwner]",
    ]),
  ]],
];

const hfPrograms = [
  ["SplToken", "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA", null, [
    ...ix("Transfer", "0x03", ["            args:", "              - { name: amount, type: u64 }", "            accounts: [source, destination, authority]"]),
    ...ix("TransferChecked", "0x0c", ["            args:", "              - { name: amount, type: u64 }", "              - { name: decimals, type: u8 }", "            accounts: [source, mint, destination, authority]"]),
    ...ix("MintTo", "0x07", ["            args:", "              - { name: amount, type: u64 }", "            accounts: [mint, destination, authority]"]),
    ...ix("Burn", "0x08", ["            args:", "              - { name: amount, type: u64 }", "            accounts: [account, mint, authority]"]),
  ]],
  ["System", "11111111111111111111111111111111", null, [
    ...ix("Transfer", "0x02000000", ["            args:", "              - { name: lamports, type: u64 }", "            accounts: [source, destination]"]),
  ]],
];

const programs = programSet === "defi+hf" ? [...defiPrograms, ...hfPrograms] : defiPrograms;

const programBlocks = programs.flatMap(([name, id, idlLine, instructions]) => {
  const head = ["      - name: " + name, "        program_id: " + (name === "System" ? '"' + id + '"' : id)];
  if (idlLine) head.push(idlLine);
  head.push("        instructions:");
  return [...head, ...instructions];
});

const lines = [
  "# GENERATED by stress/gen-config.mjs - do not edit by hand.",
  "name: svm-flow-xray-stress",
  "description: Stress variant (programSet=" + programSet + ", window=" + windowSlots + ", token_balance_fields=" + tokenBalances + ").",
  "ecosystem: svm",
  // config-dir-relative (config lives in stress/.generated/, so ../ = stress/).
  "schema: ../schema.graphql",
  "chains:",
  "  - rpc: https://api.mainnet-beta.solana.com",
  "    hypersync_config:",
  "      url: https://solana.hypersync.xyz",
  "    start_block: " + START,
  "    end_block: " + endBlock,
  "    programs_experimental:",
  ...programBlocks,
  "",
];

writeFileSync(outPath, lines.join("\n"));
console.error("wrote " + outPath + " (programSet=" + programSet + " window=" + windowSlots + " tb=" + tokenBalances + " end_block=" + endBlock + ")");
