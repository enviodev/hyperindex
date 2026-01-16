/**
 * Fuel Greeter template test
 */

import { GraphQLTestCase } from "../types.js";

interface Greeting {
  id: string;
  greeting: string;
}

interface FuelGreeterQueryResult {
  Greeting: Greeting[];
}

export const fuelGreeterTests: GraphQLTestCase<FuelGreeterQueryResult>[] = [
  {
    description: "Greeting entities exist",
    query: `
      {
        Greeting(limit: 10) {
          id
          greeting
        }
      }
    `,
    validate: (data) => {
      // Should have at least one greeting
      return data.Greeting.length > 0;
    },
  },
];
