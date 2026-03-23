import { describe, it, expect } from "vitest";
import { createTestIndexer, type User } from "generated";
import { TestHelpers } from "envio";
const { Addresses } = TestHelpers;

describe("Greeter template tests", () => {
  it("A NewGreeting event creates a User entity", async () => {
    const indexer = createTestIndexer();
    const userAddress = Addresses.defaultAddress;
    const greeting = "Hi there";

    await indexer.process({
      chains: {
        0: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            {
              contract: "Greeter",
              event: "NewGreeting",
              params: {
                greeting: { value: greeting },
                user: { bits: userAddress },
              },
            },
          ],
        },
      },
    });

    const expectedUserEntity: User = {
      id: userAddress,
      latestGreeting: greeting,
      numberOfGreetings: 1,
      greetings: [greeting],
    };

    const actualUserEntity = await indexer.User.get(userAddress);
    expect(actualUserEntity).toEqual(expectedUserEntity);
  });

  it("2 Greetings from the same users results in that user having a greeter count of 2", async () => {
    const indexer = createTestIndexer();
    const userAddress = Addresses.defaultAddress;
    const greeting = "Hi there";

    await indexer.process({
      chains: {
        0: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            {
              contract: "Greeter",
              event: "NewGreeting",
              params: {
                greeting: { value: greeting },
                user: { bits: userAddress },
              },
            },
            {
              contract: "Greeter",
              event: "NewGreeting",
              params: {
                greeting: { value: greeting },
                user: { bits: userAddress },
              },
            },
          ],
        },
      },
    });

    const actualUserEntity = await indexer.User.get(userAddress);
    expect(actualUserEntity?.numberOfGreetings).toBe(2);
  });

  it("2 Greetings from the same users results in the latest greeting being the greeting from the second event", async () => {
    const indexer = createTestIndexer();
    const userAddress = Addresses.defaultAddress;
    const greeting = "Hi there";
    const greetingAgain = "Oh hello again";

    await indexer.process({
      chains: {
        0: {
          startBlock: 0,
          endBlock: 100,
          simulate: [
            {
              contract: "Greeter",
              event: "NewGreeting",
              params: {
                greeting: { value: greeting },
                user: { bits: userAddress },
              },
            },
            {
              contract: "Greeter",
              event: "NewGreeting",
              params: {
                greeting: { value: greetingAgain },
                user: { bits: userAddress },
              },
            },
          ],
        },
      },
    });

    const actualUserEntity = await indexer.User.get(userAddress);
    expect(actualUserEntity?.latestGreeting).toBe(greetingAgain);
  });
});
