open RescriptMocha

let mockHandler: Internal.handler = Utils.magic("mock handler 1")
let mockHandler2: Internal.handler = Utils.magic("mock handler 2")
let mockContractRegister: Internal.contractRegister = Utils.magic("mock contract register 1")
let mockContractRegister2: Internal.contractRegister = Utils.magic("mock contract register 2")
let mockLogger: Pino.t = Pino.make({level: #silent})

// HandlerRegister uses a global dict for eventRegistrations that persists
// across startRegistration/finishRegistration cycles. Use unique names per test
// to avoid interference.
let testCounter = ref(0)
let uniqueName = prefix => {
  testCounter := testCounter.contents + 1
  `${prefix}_${testCounter.contents->Belt.Int.toString}`
}

let setup = () => {
  HandlerRegister.startRegistration(
    ~ecosystem="mock ecosystem"->(Utils.magic: string => Ecosystem.t),
    ~multichain=Config.Unordered,
  )
}

let cleanup = () => {
  try {
    HandlerRegister.finishRegistration()->ignore
  } catch {
  | _ => ()
  }
}

describe("HandlerRegister", () => {
  afterEach(() => {
    cleanup()
  })

  describe("setHandler", () => {
    it("allows registering a handler for an event", () => {
      setup()
      let contractName = uniqueName("Contract")
      let eventName = uniqueName("Event")

      HandlerRegister.setHandler(
        ~contractName,
        ~eventName,
        mockHandler->(Utils.magic: Internal.handler => Internal.genericHandler<'a>),
        ~eventOptions=None,
        ~logger=mockLogger,
      )

      Assert.deepEqual(
        HandlerRegister.getHandler(~contractName, ~eventName)->Belt.Option.isSome,
        true,
        ~message="Handler should be registered",
      )
    })

    it("allows registering handlers for different events on the same contract", () => {
      setup()
      let contractName = uniqueName("Contract")
      let eventName1 = uniqueName("Event")
      let eventName2 = uniqueName("Event")

      HandlerRegister.setHandler(
        ~contractName,
        ~eventName=eventName1,
        mockHandler->(Utils.magic: Internal.handler => Internal.genericHandler<'a>),
        ~eventOptions=None,
        ~logger=mockLogger,
      )
      HandlerRegister.setHandler(
        ~contractName,
        ~eventName=eventName2,
        mockHandler2->(Utils.magic: Internal.handler => Internal.genericHandler<'a>),
        ~eventOptions=None,
        ~logger=mockLogger,
      )

      Assert.deepEqual(
        HandlerRegister.getHandler(~contractName, ~eventName=eventName1)->Belt.Option.isSome,
        true,
        ~message="First handler should be registered",
      )
      Assert.deepEqual(
        HandlerRegister.getHandler(~contractName, ~eventName=eventName2)->Belt.Option.isSome,
        true,
        ~message="Second handler should be registered",
      )
    })

    it("allows registering handlers for the same event on different contracts", () => {
      setup()
      let contractName1 = uniqueName("Contract")
      let contractName2 = uniqueName("Contract")
      let eventName = uniqueName("Transfer")

      HandlerRegister.setHandler(
        ~contractName=contractName1,
        ~eventName,
        mockHandler->(Utils.magic: Internal.handler => Internal.genericHandler<'a>),
        ~eventOptions=None,
        ~logger=mockLogger,
      )
      HandlerRegister.setHandler(
        ~contractName=contractName2,
        ~eventName,
        mockHandler2->(Utils.magic: Internal.handler => Internal.genericHandler<'a>),
        ~eventOptions=None,
        ~logger=mockLogger,
      )

      Assert.deepEqual(
        HandlerRegister.getHandler(~contractName=contractName1, ~eventName)->Belt.Option.isSome,
        true,
        ~message="Handler for first contract should be registered",
      )
      Assert.deepEqual(
        HandlerRegister.getHandler(~contractName=contractName2, ~eventName)->Belt.Option.isSome,
        true,
        ~message="Handler for second contract should be registered",
      )
    })

    it("throws on duplicate handler registration for the same event", () => {
      setup()
      let contractName = uniqueName("Contract")
      let eventName = uniqueName("Event")

      HandlerRegister.setHandler(
        ~contractName,
        ~eventName,
        mockHandler->(Utils.magic: Internal.handler => Internal.genericHandler<'a>),
        ~eventOptions=None,
        ~logger=mockLogger,
      )

      Assert.throws(
        () => {
          HandlerRegister.setHandler(
            ~contractName,
            ~eventName,
            mockHandler2->(Utils.magic: Internal.handler => Internal.genericHandler<'a>),
            ~eventOptions=None,
            ~logger=mockLogger,
          )
        },
        ~message="Should throw on duplicate handler registration",
      )
    })
  })

  describe("setContractRegister", () => {
    it("throws on duplicate contractRegister for the same event", () => {
      setup()
      let contractName = uniqueName("Contract")
      let eventName = uniqueName("Event")

      HandlerRegister.setContractRegister(
        ~contractName,
        ~eventName,
        mockContractRegister
        ->(Utils.magic: Internal.contractRegister => Internal.genericContractRegister<Internal.genericContractRegisterArgs<'event, 'context>>),
        ~eventOptions=None,
        ~logger=mockLogger,
      )

      Assert.throws(
        () => {
          HandlerRegister.setContractRegister(
            ~contractName,
            ~eventName,
            mockContractRegister2
            ->(Utils.magic: Internal.contractRegister => Internal.genericContractRegister<Internal.genericContractRegisterArgs<'event, 'context>>),
            ~eventOptions=None,
            ~logger=mockLogger,
          )
        },
        ~message="Should throw on duplicate contractRegister registration",
      )
    })
  })
})
