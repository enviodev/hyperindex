let lensProtocolProfilesTransferEventHandler = (event: LensProtocolProfilesTransfer, context) => {

  if (event.to !== 0x00) {

    let account = context.Accounts.upsert({ address: event.to }, event.to)

    //external stuff
    let handle = await getHandleOfUser(event.to)

    let profileToken = context.ProfileToken.upsert({
      id: event.tokenId,
      handle: event....
        owner: event.to
    })
  } else {
    context.ProfileToken.delete(event.tokenId)
  }
  //check event.from = null 0x00
  //create ProfileToken & Account
  //else get account, remove ProfileToken from account entity
  //create/add Account of to and link ProfileToken entity
}


// entity function
// - insert
// - update
// - delete
// - upsert
