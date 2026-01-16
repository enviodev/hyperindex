/**
 * EVM ERC20 template test
 */

import { GraphQLTestCase } from "../types.js";

interface Account {
  id: string;
  balance: string;
}

interface Erc20QueryResult {
  Account: Account[];
}

export const erc20Tests: GraphQLTestCase<Erc20QueryResult>[] = [
  {
    description: "Account entities exist with balances",
    query: `
      {
        Account(limit: 10) {
          id
          balance
        }
      }
    `,
    validate: (data) => {
      // Should have at least one account with a balance
      return (
        data.Account.length > 0 &&
        data.Account.some((a) => BigInt(a.balance) > 0n)
      );
    },
  },
];
