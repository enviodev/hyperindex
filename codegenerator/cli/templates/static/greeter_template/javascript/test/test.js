const { expect } = require("chai");
const {
  MockDb,
  createMockGreeterNewGreetingEvent,
  eventProcessors,
} = require("../generated/src/TestHelpers.bs");
const { Addresses } = require("../generated/src/bindings/Ethers.bs");

describe("Greeter template tests", () => {
  it("A NewGreeting event creates a Greeting entity", () => {
    // Initializing the mock database
    let mockDbInitial = MockDb.createMockDb();

    // Initializing values for mock event
    let userAddress = Addresses.defaultAddress;
    let greeting = "Hi there";

    // Creating a mock event
    let mockNewGreetingEvent = createMockGreeterNewGreetingEvent({
      greeting: greeting,
      user: userAddress,
    });

    // Processing the mock event on the mock database
    let updatedMockDb = eventProcessors.Greeter.NewGreeting.processEvent({
      event: mockNewGreetingEvent,
      mockDb: mockDbInitial,
    });

    // Expected entity that should be created
    let expectedGreetingEntity = {
      id: userAddress,
      latestGreeting: greeting,
      numberOfGreetings: 1,
      greetings: [greeting],
    };

    // Getting the entity from the mock database
    let dbEntity = updatedMockDb.entities.Greeting.get(userAddress);

    // Asserting that the entity in the mock database is the same as the expected entity
    expect(expectedGreetingEntity).to.deep.equal(dbEntity);
  });

  it("2 Greetings from the same users results in that user having a greeter count of 2", () => {
    // Initializing the mock database
    let mockDbInitial = MockDb.createMockDb();

    // Initializing values for mock event
    let userAddress = Addresses.defaultAddress;
    let greeting = "Hi there";
    let greetingAgain = "Oh hello again";

    // Creating a mock event
    let mockNewGreetingEvent = createMockGreeterNewGreetingEvent({
      greeting: greeting,
      user: userAddress,
    });

    // Creating a mock event
    let mockNewGreetingEvent2 = createMockGreeterNewGreetingEvent({
      greeting: greetingAgain,
      user: userAddress,
    });

    // Processing the mock event on the mock database
    let updatedMockDb = eventProcessors.Greeter.NewGreeting.processEvent({
      event: mockNewGreetingEvent,
      mockDb: mockDbInitial,
    });

    // Processing the mock event on the updated mock database
    let updatedMockDb2 = eventProcessors.Greeter.NewGreeting.processEvent({
      event: mockNewGreetingEvent2,
      mockDb: updatedMockDb,
    });

    let expectedGreetingCount = 2;

    // Getting the entity from the mock database
    let dbEntity = updatedMockDb2.entities.Greeting.get(userAddress);

    // Asserting that the field value of the entity in the mock database is the same as the expected field value
    expect(dbEntity?.numberOfGreetings).to.deep.equal(expectedGreetingCount);
  });

  it("2 Greetings from the same users results in the latest greeting being the greeting from the second event", () => {
    // Initializing the mock database
    let mockDbInitial = MockDb.createMockDb();

    // Initializing values for mock event
    let userAddress = Addresses.defaultAddress;
    let greeting = "Hi there";
    let greetingAgain = "Oh hello again";

    // Creating a mock event
    let mockNewGreetingEvent = createMockGreeterNewGreetingEvent({
      greeting: greeting,
      user: userAddress,
    });

    // Creating a mock event
    let mockNewGreetingEvent2 = createMockGreeterNewGreetingEvent({
      greeting: greetingAgain,
      user: userAddress,
    });

    // Processing the mock event on the mock database
    let updatedMockDb = eventProcessors.Greeter.NewGreeting.processEvent({
      event: mockNewGreetingEvent,
      mockDb: mockDbInitial,
    });

    // Processing the mock event on the updated mock database
    let updatedMockDb2 = eventProcessors.Greeter.NewGreeting.processEvent({
      event: mockNewGreetingEvent2,
      mockDb: updatedMockDb,
    });

    let expectedGreeting = greetingAgain;

    // Getting the entity from the mock database
    let dbEntity = updatedMockDb2.entities.Greeting.get(userAddress);

    // Asserting that the field value of the entity in the mock database is the same as the expected field value
    expect(dbEntity?.latestGreeting).to.deep.equal(expectedGreeting);
  });
});
