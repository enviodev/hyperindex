import assert from "assert";
import { TestHelpers, User } from "generated";
const { MockDb, Greeter, Addresses } = TestHelpers;

describe("Greeter template tests", () => {
  it("A NewGreeting event creates a User entity", async () => {
    // Initializing the mock database
    const mockDbInitial = MockDb.createMockDb();

    // Initializing values for mock event
    const userAddress = Addresses.defaultAddress;
    const greeting = "Hi there";

    // Creating a mock event
    const mockNewGreetingEvent = Greeter.NewGreeting.createMockEvent({
      greeting: greeting,
      user: userAddress,
    });

    // Processing the mock event on the mock database
    const updatedMockDb = await Greeter.NewGreeting.processEvent({
      event: mockNewGreetingEvent,
      mockDb: mockDbInitial,
    });

    // Expected entity that should be created
    const expectedUserEntity: User = {
      id: userAddress,
      latestGreeting: greeting,
      numberOfGreetings: 1,
      greetings: [greeting],
    };

    // Getting the entity from the mock database
    const actualUserEntity = updatedMockDb.entities.User.get(userAddress);

    // Asserting that the entity in the mock database is the same as the expected entity
    assert.deepEqual(expectedUserEntity, actualUserEntity);
  });

  it("2 Greetings from the same users results in that user having a greeter count of 2", async () => {
    // Initializing the mock database
    const mockDbInitial = MockDb.createMockDb();
    // Initializing values for mock event
    const userAddress = Addresses.defaultAddress;
    const greeting = "Hi there";
    const greetingAgain = "Oh hello again";

    // Creating a mock event
    const mockNewGreetingEvent = Greeter.NewGreeting.createMockEvent({
      greeting: greeting,
      user: userAddress,
    });

    // Creating a mock event
    const mockNewGreetingEvent2 = Greeter.NewGreeting.createMockEvent({
      greeting: greetingAgain,
      user: userAddress,
    });

    // Processing the mock event on the mock database
    const updatedMockDb = await Greeter.NewGreeting.processEvent({
      event: mockNewGreetingEvent,
      mockDb: mockDbInitial,
    });

    // Processing the mock event on the updated mock database
    const updatedMockDb2 = await Greeter.NewGreeting.processEvent({
      event: mockNewGreetingEvent2,
      mockDb: updatedMockDb,
    });

    // Getting the entity from the mock database
    const actualUserEntity = updatedMockDb2.entities.User.get(userAddress);

    // Asserting that the field value of the entity in the mock database is the same as the expected field value
    assert.equal(2, actualUserEntity?.numberOfGreetings);
  });

  it("2 Greetings from the same users results in the latest greeting being the greeting from the second event", async () => {
    // Initializing the mock database
    const mockDbInitial = MockDb.createMockDb();
    // Initializing values for mock event
    const userAddress = Addresses.defaultAddress;
    const greeting = "Hi there";
    const greetingAgain = "Oh hello again";

    // Creating a mock event
    const mockNewGreetingEvent = Greeter.NewGreeting.createMockEvent({
      greeting: greeting,
      user: userAddress,
    });

    // Creating a mock event
    const mockNewGreetingEvent2 = Greeter.NewGreeting.createMockEvent({
      greeting: greetingAgain,
      user: userAddress,
    });

    // Processing the mock event on the mock database
    const updatedMockDb = await Greeter.NewGreeting.processEvent({
      event: mockNewGreetingEvent,
      mockDb: mockDbInitial,
    });

    // Processing the mock event on the updated mock database
    const updatedMockDb2 = await Greeter.NewGreeting.processEvent({
      event: mockNewGreetingEvent2,
      mockDb: updatedMockDb,
    });

    // Getting the entity from the mock database
    const actualUserEntity = updatedMockDb2.entities.User.get(userAddress);

    const expectedGreeting: string = greetingAgain;

    // Asserting that the field value of the entity in the mock database is the same as the expected field value
    assert.equal(expectedGreeting, actualUserEntity?.latestGreeting);
  });
});
