open Types
open Entities

Handlers.ERC20Factory.TokenCreated.contractRegister(({event, context}) => {
  context.addERC20(event.params.token)
})

let join = (a, b) => a ++ "-" ++ b

let makeAccountTokenId = (~account_id, ~tokenAddress) => {
  account_id->join(tokenAddress)
}

let makeAccountToken = (~account_id, ~tokenAddress, ~balance): AccountToken.t => {
  id: makeAccountTokenId(~account_id, ~tokenAddress),
  account_id,
  tokenAddress,
  balance,
}

let makeApprovalId = (~tokenAddress, ~owner_id, ~spender_id) =>
  tokenAddress->join(owner_id)->join(spender_id)

let makeApprivalEntity = (~tokenAddress, ~owner_id, ~spender_id, ~amount) => {
  Approval.id: makeApprovalId(~tokenAddress, ~owner_id, ~spender_id),
  amount,
  owner_id,
  spender_id,
  tokenAddress,
}

let createNewAccountWithZeroBalance = (
  ~account_id,
  ~tokenAddress,
  ~setAccount,
  ~setAccountToken,
) => {
  let accountObject: Account.t = {
    id: account_id,
  }
  // setting the accountEntity with the new transfer field value
  setAccount(accountObject)

  let accountToken = makeAccountToken(~account_id, ~tokenAddress, ~balance=Ethers.BigInt.fromInt(0))

  setAccountToken(accountToken)

  accountToken
}

Handlers.ERC20.Approval.handlerWithLoader({
  loader: ({event, context}) => {
    context.account.get(event.params.owner->Ethers.ethAddressToString)
  },
  handler: async ({event, context, loaderReturn}) => {
    let ownerAccount = loaderReturn

    let account_id = event.params.owner->Ethers.ethAddressToString
    let tokenAddress = event.srcAddress->Ethers.ethAddressToString
    if ownerAccount->Belt.Option.isNone {
      createNewAccountWithZeroBalance(
        ~account_id,
        ~tokenAddress,
        ~setAccount=context.account.set,
        ~setAccountToken=context.accountToken.set,
      )->ignore
    }

    let approvalEntity = makeApprivalEntity(
      ~spender_id=event.params.spender->Ethers.ethAddressToString,
      ~owner_id=account_id,
      ~tokenAddress,
      ~amount=event.params.value,
    )

    // this is the same for create or update as the amount is overwritten
    context.approval.set(approvalEntity)

    // context.account.load(event.params.owner->Ethers.ethAddressToString)
  },
})

let manipulateAccountTokenBalance = (fn, accountToken: AccountToken.t, amount): AccountToken.t => {
  {...accountToken, balance: accountToken.balance->fn(amount)}
}

let addToBalance = manipulateAccountTokenBalance(Ethers.BigInt.add)
let subFromBalance = manipulateAccountTokenBalance(Ethers.BigInt.sub)

let manipulateAccountBalance = (
  optAccountToken,
  fn,
  ~value,
  ~account_id,
  ~tokenAddress,
  ~setAccount,
  ~setAccountToken,
) =>
  switch optAccountToken {
  | Some(accountToken) => accountToken
  | None =>
    createNewAccountWithZeroBalance(~account_id, ~tokenAddress, ~setAccount, ~setAccountToken)
  }
  ->fn(value)
  ->setAccountToken

Handlers.ERC20.Transfer.handlerWithLoader({
  loader: ({event, context}) => {
    let fromAccount_id = event.params.from->Ethers.ethAddressToString
    let toAccount_id = event.params.to->Ethers.ethAddressToString
    let tokenAddress = event.srcAddress->Ethers.ethAddressToString
    let fromAccountToken_id = makeAccountTokenId(~tokenAddress, ~account_id=fromAccount_id)
    let toAccountToken_id = makeAccountTokenId(~tokenAddress, ~account_id=toAccount_id)

    (
      context.accountToken.get(fromAccountToken_id),
      context.accountToken.get(toAccountToken_id),
    )->Promise.all2
  },
  handler: async ({event, context, loaderReturn}) => {
    let (senderAccountToken, receiverAccountToken) = loaderReturn
    let {params: {from, to, value}, srcAddress} = event
    let fromAccount_id = from->Ethers.ethAddressToString
    let toAccount_id = to->Ethers.ethAddressToString
    let tokenAddress = srcAddress->Ethers.ethAddressToString

    let manipulateAccountBalance = manipulateAccountBalance(
      ~value,
      ~tokenAddress,
      ~setAccountToken=context.accountToken.set,
      ~setAccount=context.account.set,
    )

    senderAccountToken->manipulateAccountBalance(subFromBalance, ~account_id=fromAccount_id)
    receiverAccountToken->manipulateAccountBalance(addToBalance, ~account_id=toAccount_id)
  },
})

Handlers.ERC20Factory.DeleteUser.handler(async ({event, context}) => {
  context.account.deleteUnsafe(event.params.user->Ethers.ethAddressToString)
})
