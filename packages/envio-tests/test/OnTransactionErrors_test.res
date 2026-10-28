// Invalid `indexer.onTransaction` options throw at the user's registration call
// site, and a registration that runs on every transaction of a chain says so.
// The values the generated types already reject are cast through, the way a
// JavaScript user would write them.
let _ = InternalTestIndexer.fromUserApi(
  ~configYaml=`
name: on-transaction-errors
contracts:
  - name: Token
    events:
      - event: Transfer(address indexed from, address indexed to, uint256 value)
chains:
  - id: 1
    start_block: 0
    contracts:
      - name: Token
        address: "0x1111111111111111111111111111111111111111"
`,
  ~schema=`
type Noop {
  id: ID!
}
`,
  ~test=`
import { describe, it } from "vitest";
import { indexer } from "envio";

const WALLET = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

const errorOf = (options: object) => {
  try {
    indexer.onTransaction({ name: "treasury", ...options } as any, async () => {});
    return "no error";
  } catch (error) {
    return (error as Error).message;
  }
};

const invalidFilter = (reason: string) =>
  '\`indexer.onTransaction("treasury")\` \`where\` returned an invalid filter: ' + reason;

describe("onTransaction registration errors", () => {
  it("rejects a where that isn't a function", (t) => {
    t.expect({
      object: errorOf({ where: { transaction: { from: [WALLET] } } }),
      string: errorOf({ where: "yes" }),
    }).toEqual({
      object:
        '\`indexer.onTransaction("treasury")\` expected \`where\` to be a function or omitted, but got object.',
      string:
        '\`indexer.onTransaction("treasury")\` expected \`where\` to be a function or omitted, but got string.',
    });
  });

  it("rejects a where result that is neither a boolean nor a filter", (t) => {
    t.expect({
      number: errorOf({ where: () => 1 }),
      array: errorOf({ where: () => [] }),
      missingReturn: errorOf({ where: () => {} }),
    }).toEqual({
      number:
        '\`indexer.onTransaction("treasury")\` \`where\` predicate returned an invalid value of type number. Expected boolean or a filter object.',
      array:
        '\`indexer.onTransaction("treasury")\` \`where\` predicate returned an invalid value of type object. Expected boolean or a filter object.',
      missingReturn:
        '\`indexer.onTransaction("treasury")\` \`where\` predicate returned an invalid value of type undefined. Expected boolean or a filter object.',
    });
  });

  it("rejects a filter with unknown keys or malformed values", (t) => {
    t.expect({
      unknownKey: errorOf({ where: () => ({ block: { number: { _gte: 1 } } }) }),
      unknownTransactionKey: errorOf({ where: () => ({ transaction: { sender: [WALLET] } }) }),
      fromNotAList: errorOf({ where: () => ({ transaction: { from: WALLET } }) }),
      badAddress: errorOf({ where: () => ({ transaction: { from: [WALLET], to: ["0x12"] } }) }),
      badSighash: errorOf({ where: () => ({ transaction: { sighash: ["0xa9059cbb00"] } }) }),
      badStatus: errorOf({ where: () => ({ transaction: { from: [WALLET], status: 2 } }) }),
    }).toEqual({
      unknownKey: invalidFilter(
        'RescriptSchemaError: Failed parsing at root. Reason: Encountered disallowed excess key "block" on an object',
      ),
      unknownTransactionKey: invalidFilter(
        'RescriptSchemaError: Failed parsing at ["transaction"]. Reason: Encountered disallowed excess key "sender" on an object',
      ),
      fromNotAList: invalidFilter(
        'RescriptSchemaError: Failed parsing at ["transaction"]["from"]. Reason: Expected array<string> | undefined, received "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"',
      ),
      badAddress: invalidFilter('transaction.to must list EVM addresses, got "0x12".'),
      badSighash: invalidFilter(
        'transaction.sighash must list 4-byte function selectors like "0xa9059cbb", got "0xa9059cbb00".',
      ),
      badStatus: invalidFilter("transaction.status must be 0 (reverted) or 1 (succeeded), got 2."),
    });
  });

  it("rejects fields the transaction table doesn't have", (t) => {
    t.expect({
      sighash: errorOf({ fields: { transaction: ["sighash"] } }),
      log: errorOf({ fields: { log: ["data"] } }),
      notAnObject: errorOf({ fields: ["hash"] }),
    }).toEqual({
      sighash:
        'Invalid "sighash" field in the fields.transaction option of \`indexer.onTransaction("treasury")\`. Valid transaction fields: "transactionIndex", "hash", "from", "to", "gas", "gasPrice", "maxPriorityFeePerGas", "maxFeePerGas", "cumulativeGasUsed", "effectiveGasPrice", "gasUsed", "input", "nonce", "value", "v", "r", "s", "contractAddress", "logsBloom", "root", "status", "yParity", "maxFeePerBlobGas", "blobVersionedHashes", "type", "l1Fee", "l1GasPrice", "l1GasUsed", "l1FeeScalar", "gasUsedForL1", "accessList", "authorizationList".',
      log:
        'Invalid "log" key in the fields option of \`indexer.onTransaction("treasury")\`. Valid keys: "transaction", "block".',
      notAnObject:
        'The fields option of \`indexer.onTransaction("treasury")\` must be an object of transaction and block field names.',
    });
  });

  it("accepts a skip and a filter on every chain", (t) => {
    t.expect({
      skip: errorOf({ where: () => false }),
      filter: errorOf({ where: ({ chain }: any) => chain.id === 1 && { transaction: { from: [WALLET] } } }),
      fields: errorOf({
        where: () => ({ transaction: { to: [WALLET], sighash: ["0xa9059cbb"], status: 1 } }),
        fields: { transaction: ["input", "value"], block: ["timestamp"] },
      }),
    }).toEqual({ skip: "no error", filter: "no error", fields: "no error" });
  });
});
`,
)
