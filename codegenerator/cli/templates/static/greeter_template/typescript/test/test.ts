import assert from "assert";
import { MockDb, Greeter } from "../generated/src/TestHelpers.gen";
import { GreetingEntity } from "../generated/src/Types.gen";
import { Addresses } from "../generated/src/bindings/Ethers.gen";

describe("Greeter template tests", () => {
  it("A NewGreeting event creates a Greeting entity", () => {
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
    const updatedMockDb = Greeter.NewGreeting.processEvent({
      event: mockNewGreetingEvent,
      mockDb: mockDbInitial,
    });

    // Expected entity that should be created
    const expectedGreetingEntity: GreetingEntity = {
      id: userAddress,
      latestGreeting: greeting,
      numberOfGreetings: 1,
      greetings: [greeting],
    };

    // Getting the entity from the mock database
    const actualGreetingEntity =
      updatedMockDb.entities.Greeting.get(userAddress);

    // Asserting that the entity in the mock database is the same as the expected entity
    assert.deepEqual(expectedGreetingEntity, actualGreetingEntity);
  });

  it("2 Greetings from the same users results in that user having a greeter count of 2", () => {
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
    const updatedMockDb = Greeter.NewGreeting.processEvent({
      event: mockNewGreetingEvent,
      mockDb: mockDbInitial,
    });

    // Processing the mock event on the updated mock database
    const updatedMockDb2 = Greeter.NewGreeting.processEvent({
      event: mockNewGreetingEvent2,
      mockDb: updatedMockDb,
    });

    // Getting the entity from the mock database
    const actualGreetingEntity =
      updatedMockDb2.entities.Greeting.get(userAddress);

    // Asserting that the field value of the entity in the mock database is the same as the expected field value
    assert.equal(2, actualGreetingEntity?.numberOfGreetings);
  });

  it("2 Greetings from the same users results in the latest greeting being the greeting from the second event", () => {
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
    const updatedMockDb = Greeter.NewGreeting.processEvent({
      event: mockNewGreetingEvent,
      mockDb: mockDbInitial,
    });

    // Processing the mock event on the updated mock database
    const updatedMockDb2 = Greeter.NewGreeting.processEvent({
      event: mockNewGreetingEvent2,
      mockDb: updatedMockDb,
    });

    // Getting the entity from the mock database
    const actualGreetingEntity =
      updatedMockDb2.entities.Greeting.get(userAddress);

    const expectedGreeting: string = greetingAgain;

    // Asserting that the field value of the entity in the mock database is the same as the expected field value
    assert.equal(expectedGreeting, actualGreetingEntity?.latestGreeting);
  });
});
