open RescriptMocha
open Mocha
open Belt

describe("Greeter template tests", () => {
  it("A NewGreeting event creates a Greeting entity", () => {
    // Initializing the mock database
    let mockDbInitial = TestHelpers.MockDb.createMockDb()
    
    // Initializing values for mock event
    let userAddress = Ethers.Addresses.defaultAddress
    let greeting = "Hi there"

    // Creating a mock event
    let mockNewGreetingEvent: Types.GreeterContract.NewGreetingEvent.log = TestHelpers.createMockGreeterNewGreetingEvent(
      ~args={
        greeting,
        user: userAddress,
      },
    )

    // Processing the mock event on the mock database
    let updatedMockDb = TestHelpers.eventProcessors.greeter.newGreeting.processEvent({
      event: mockNewGreetingEvent,
      mockDb: mockDbInitial,
    })
    
    // Expected entity that should be created
    let expectedGreetingEntity: Types.greetingEntity = {
      id: userAddress->Ethers.ethAddressToString,
      latestGreeting: greeting,
      numberOfGreetings: 1,
      greetings: [greeting],
    }

    // Getting the entity from the mock database
    let dbEntity =
      updatedMockDb.entities.greeting.get(userAddress->Ethers.ethAddressToString)->Option.getExn

    // Asserting that the entity in the mock database is the same as the expected entity
    Assert.deep_equal(expectedGreetingEntity, dbEntity)
  })

  it("2 Greetings from the same users results in that user having a greeter count of 2", () => {
    // Initializing the mock database
    let mockDbInitial = TestHelpers.MockDb.createMockDb()

    // Initializing values for mock event
    let userAddress = Ethers.Addresses.defaultAddress
    let greeting = "Hi there"
    let greetingAgain = "Oh hello again"

    // Creating a mock event
    let mockNewGreetingEvent: Types.GreeterContract.NewGreetingEvent.log = TestHelpers.createMockGreeterNewGreetingEvent(
      ~args={
        greeting,
        user: userAddress,
      },
    )

    // Creating a mock event
    let mockNewGreetingEvent2: Types.GreeterContract.NewGreetingEvent.log = TestHelpers.createMockGreeterNewGreetingEvent(
      ~args={
        greeting: greetingAgain,
        user: userAddress,
      },
    )

    // Processing the mock event on the mock database
    let updatedMockDb = TestHelpers.eventProcessors.greeter.newGreeting.processEvent({
      event: mockNewGreetingEvent,
      mockDb: mockDbInitial,
    })

    // Processing the mock event on the updated mock database
    let updatedMockDb2 = TestHelpers.eventProcessors.greeter.newGreeting.processEvent({
      event: mockNewGreetingEvent2,
      mockDb: updatedMockDb,
    })

    let expectedGreetingCount: int = 2

    // Getting the entity from the mock database
    let dbEntity =
      updatedMockDb2.entities.greeting.get(userAddress->Ethers.ethAddressToString)->Option.getExn

    // Asserting that the field value of the entity in the mock database is the same as the expected field value
    Assert.equal(dbEntity.numberOfGreetings, expectedGreetingCount)
  })
  it(
    "2 Greetings from the same users results in the latest greeting being the greeting from the second event",
    () => {
      // Initializing the mock database
      let mockDbInitial = TestHelpers.MockDb.createMockDb()

      // Initializing values for mock event
      let userAddress = Ethers.Addresses.defaultAddress
      let greeting = "Hi there"
      let greetingAgain = "Oh hello again"

      // Creating a mock event
      let mockNewGreetingEvent: Types.GreeterContract.NewGreetingEvent.log = TestHelpers.createMockGreeterNewGreetingEvent(
        ~args={
          greeting,
          user: userAddress,
        },
      )

      // Creating a mock event
      let mockNewGreetingEvent2: Types.GreeterContract.NewGreetingEvent.log = TestHelpers.createMockGreeterNewGreetingEvent(
        ~args={
          greeting: greetingAgain,
          user: userAddress,
        },
      )

      // Processing the mock event on the mock database
      let updatedMockDb = TestHelpers.eventProcessors.greeter.newGreeting.processEvent({
        event: mockNewGreetingEvent,
        mockDb: mockDbInitial,
      })

      // Processing the mock event on the updated mock database
      let updatedMockDb2 = TestHelpers.eventProcessors.greeter.newGreeting.processEvent({
        event: mockNewGreetingEvent2,
        mockDb: updatedMockDb,
      })

      let expectedGreeting: string = greetingAgain

      // Getting the entity from the mock database
      let dbEntity =
        updatedMockDb2.entities.greeting.get(userAddress->Ethers.ethAddressToString)->Option.getExn

      // Asserting that the field value of the entity in the mock database is the same as the expected field value
      Assert.equal(dbEntity.latestGreeting, expectedGreeting)
    },
  )
})
