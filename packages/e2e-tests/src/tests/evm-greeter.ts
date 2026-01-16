/**
 * EVM Greeter template test
 */

import { GraphQLTestCase } from "../types.js";

interface User {
  id: string;
  greetings: string[];
  numberOfGreetings: number;
}

interface GreeterQueryResult {
  User_by_pk: User | null;
}

export const greeterTests: GraphQLTestCase<GreeterQueryResult>[] = [
  {
    description: "User entity has correct greetings",
    query: `
      {
        User_by_pk(id: "0xf28eA36e3E68Aff0e8c9bFF8037ba2150312ac48") {
          id
          greetings
          numberOfGreetings
        }
      }
    `,
    validate: (data) => {
      const user = data.User_by_pk;
      if (!user) return false;

      const hasExpectedGreetings =
        user.greetings.includes("gm Linea") &&
        user.greetings.includes("gm") &&
        user.greetings.includes("gn") &&
        user.greetings.includes("gm paris");

      const hasMinGreetings = user.numberOfGreetings >= 3;

      return hasExpectedGreetings && hasMinGreetings;
    },
  },
];
