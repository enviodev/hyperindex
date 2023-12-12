open RescriptMocha
open Mocha
open Belt
open TestHelpers

describe("Transfers", () => {
  it("Transfer subtracts the from account balance and adds to the to account balance", () => {
    //Instantiate a mock DB
    let mockDb = MockDb.createMockDb()

    //Get mock addresses from helpers
    let userAddress1 = Ethers.Addresses.mockAddresses[0]->Option.getUnsafe
    let userAddress2 = Ethers.Addresses.mockAddresses[1]->Option.getUnsafe

    //Make a mock entity to set the initial state of the mock db
    let mockAccountEntity: Types.accountEntity = {
      id: userAddress1->Ethers.ethAddressToString,
      balance: Ethers.BigInt.fromInt(5),
    }

    //Set an initial state for the user
    mockDb.entities.account.set(mockAccountEntity)

    //Create a mock Transfer event from userAddress1 to userAddress2
    let mockTransfer = ERC20.Transfer.createMockEvent({
      from: userAddress1,
      to: userAddress2,
      value: Ethers.BigInt.fromInt(3),
    })

    //Process the mockEvent
    //This takes in the mockDb and returns a new updated mockDb.
    //The initial mockDb is not mutated with processEvent
    let mockDbAfterTransfer = ERC20.Transfer.processEvent({
      event: mockTransfer,
      mockDb,
    })

    //Get the balance of userAddress1 after the transfer
    let account1Balance =
      mockDbAfterTransfer.entities.account.get(userAddress1->Ethers.ethAddressToString)->Option.map(
        a => a.balance,
      )

    //Assert the expected balance
    Assert.equal(
      Some(Ethers.BigInt.fromInt(2)),
      account1Balance,
      ~message="Should have subtracted transfer amount 3 from userAddress1 balance 5",
    )

    //Get the balance of userAddress2 after the transfer
    let account2Balance =
      mockDbAfterTransfer.entities.account.get(userAddress2->Ethers.ethAddressToString)->Option.map(
        a => a.balance,
      )
    //Assert the expected balance
    Assert.equal(
      Some(Ethers.BigInt.fromInt(3)),
      account2Balance,
      ~message="Should have added transfer amount 3 to userAddress2 balance 0",
    )
  })
})
