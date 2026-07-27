// Fuel end-to-end through the public user API: a Fuel config + handlers, with
// events driven by `createTestIndexer().process({simulate})`.
let _ = InternalTestIndexer.fromUserApi(
  ~files=Dict.fromArray([("abis/greeter-abi.json", FuelAbiFixtures.greeter)]),
  ~configYaml=`
name: fuel-greeter
ecosystem: fuel
chains:
  - id: 0
    start_block: 0
    contracts:
      - name: Greeter
        address: 0xb9bc445e5696c966dcf7e5d1237bd03c04e3ba6929bdaedfeebc7aae784c3a0b
        abi_file_path: abis/greeter-abi.json
        events:
          - name: NewGreeting
          - name: ClearGreeting
`,
  ~schema=`
type User {
  id: ID!
  latestGreeting: String!
  numberOfGreetings: Int!
  greetings: [String!]!
}
`,
  ~handlers=`
import { indexer, type User } from "envio";

indexer.onEvent({ contract: "Greeter", event: "NewGreeting" }, async ({ event, context }) => {
  const userId = event.params.user.bits;
  const latestGreeting = event.params.greeting.value;
  const current = await context.User.get(userId);

  const user: User = current
    ? {
        id: userId,
        latestGreeting,
        numberOfGreetings: current.numberOfGreetings + 1,
        greetings: [...current.greetings, latestGreeting],
      }
    : {
        id: userId,
        latestGreeting,
        numberOfGreetings: 1,
        greetings: [latestGreeting],
      };

  context.User.set(user);
});

indexer.onEvent({ contract: "Greeter", event: "ClearGreeting" }, async ({ event, context }) => {
  const current = await context.User.get(event.params.user.bits);
  if (current) {
    context.User.set({ ...current, latestGreeting: "" });
  }
});
`,
  ~test=`
import { describe, it } from "vitest";
import { createTestIndexer, type User, TestHelpers } from "envio";

const { Addresses } = TestHelpers;

const newGreeting = (user: string, greeting: string) =>
  ({
    contract: "Greeter",
    event: "NewGreeting",
    params: { greeting: { value: greeting }, user: { bits: user } },
  }) as const;

describe("Fuel Greeter", () => {
  it("creates a User from a NewGreeting", async (t) => {
    const indexer = createTestIndexer();
    const user = Addresses.defaultAddress;

    await indexer.process({
      chains: { 0: { simulate: [newGreeting(user, "Hi there")] } },
    });

    const expected: User = {
      id: user,
      latestGreeting: "Hi there",
      numberOfGreetings: 1,
      greetings: ["Hi there"],
    };
    t.expect(await indexer.User.getOrThrow(user)).toEqual(expected);
  });

  it("accumulates greetings and keeps the latest one", async (t) => {
    const indexer = createTestIndexer();
    const user = Addresses.defaultAddress;

    await indexer.process({
      chains: {
        0: {
          simulate: [
            newGreeting(user, "Hi there"),
            newGreeting(user, "Oh hello again"),
          ],
        },
      },
    });

    const expected: User = {
      id: user,
      latestGreeting: "Oh hello again",
      numberOfGreetings: 2,
      greetings: ["Hi there", "Oh hello again"],
    };
    t.expect(await indexer.User.getOrThrow(user)).toEqual(expected);
  });

  it("clears the latest greeting on ClearGreeting", async (t) => {
    const indexer = createTestIndexer();
    const user = Addresses.defaultAddress;

    await indexer.process({
      chains: {
        0: {
          simulate: [
            newGreeting(user, "Hi there"),
            {
              contract: "Greeter",
              event: "ClearGreeting",
              params: { user: { bits: user } },
            },
          ],
        },
      },
    });

    const expected: User = {
      id: user,
      latestGreeting: "",
      numberOfGreetings: 1,
      greetings: ["Hi there"],
    };
    t.expect(await indexer.User.getOrThrow(user)).toEqual(expected);
  });
});
`,
)
