open RescriptMocha
open Mocha
open Belt
open TestHelpers

describe("Transfers", () => {
  it("Transfer subtracts the from account balance and adds to the to account balance", () => {
    //Get mock addresses from helpers
    let userAddress1 = Ethers.Addresses.mockAddresses[0]->Option.getUnsafe
    let userAddress2 = Ethers.Addresses.mockAddresses[1]->Option.getUnsafe

    let account_id = userAddress1->Ethers.ethAddressToString
    //Make a mock entity to set the initial state of the mock db
    let mockAccountEntity: Types.accountEntity = {
      id: account_id,
    }
    let tokenAddress = Ethers.Addresses.defaultAddress->Ethers.ethAddressToString
    let mockAccountTokenEntity = EventHandlers.makeAccountToken(
      ~account_id,
      ~tokenAddress,
      ~balance=Ethers.BigInt.fromInt(5),
    )

    //Set an initial state for the user
    //Note: set and delete functions do not mutate the mockDb, they return a new
    //mockDb with with modified state
    let mockDb = MockDb.createMockDb().entities.account.set(
      mockAccountEntity,
    ).entities.accountToken.set(mockAccountTokenEntity)

    //Create a mock Transfer event from userAddress1 to userAddress2
    let mockTransfer = ERC20.Transfer.createMockEvent({
      from: userAddress1,
      to: userAddress2,
      value: Ethers.BigInt.fromInt(3),
    })

    //Process the mockEvent
    //Note: processEvent functions do not mutate the mockDb, they return a new
    //mockDb with with modified state
    let mockDbAfterTransfer = ERC20.Transfer.processEvent({
      event: mockTransfer,
      mockDb,
    })

    //Get the balance of userAddress1 after the transfer
    let account1Balance =
      mockDbAfterTransfer.entities.accountToken.get(
        EventHandlers.makeAccountTokenId(~account_id, ~tokenAddress),
      )->Option.map(a => a.balance)

    //Assert the expected balance
    Assert.equal(
      Some(Ethers.BigInt.fromInt(2)),
      account1Balance,
      ~message="Should have subtracted transfer amount 3 from userAddress1 balance 5",
    )

    //Get the balance of userAddress2 after the transfer
    let account2Balance =
      mockDbAfterTransfer.entities.accountToken.get(
        EventHandlers.makeAccountTokenId(
          ~account_id=userAddress2->Ethers.ethAddressToString,
          ~tokenAddress,
        ),
      )->Option.map(a => a.balance)
    //Assert the expected balance
    Assert.equal(
      Some(Ethers.BigInt.fromInt(3)),
      account2Balance,
      ~message="Should have added transfer amount 3 to userAddress2 balance 0",
    )
  })
})
