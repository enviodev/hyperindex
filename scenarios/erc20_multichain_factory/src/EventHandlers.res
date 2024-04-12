open Types

Handlers.ERC20FactoryContract.TokenCreated.loader(({event, context}) => {
  context.contractRegistration.addERC20(event.params.token)
})

Handlers.ERC20Contract.Approval.loader(({event, context}) => {
  context.account.load(event.params.owner->Ethers.ethAddressToString)
})

let join = (a, b) => a ++ "-" ++ b

let makeAccountTokenId = (~account_id, ~tokenAddress) => {
  account_id->join(tokenAddress)
}

let makeAccountToken = (~account_id, ~tokenAddress, ~balance): accountTokenEntity => {
  id: makeAccountTokenId(~account_id, ~tokenAddress),
  account_id,
  tokenAddress,
  balance,
}

let makeApprovalId = (~tokenAddress, ~owner_id, ~spender_id) =>
  tokenAddress->join(owner_id)->join(spender_id)

let makeApprivalEntity = (~tokenAddress, ~owner_id, ~spender_id, ~amount) => {
  id: makeApprovalId(~tokenAddress, ~owner_id, ~spender_id),
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
  let accountObject: accountEntity = {
    id: account_id,
  }
  // setting the accountEntity with the new transfer field value
  setAccount(accountObject)

  let accountToken = makeAccountToken(~account_id, ~tokenAddress, ~balance=Ethers.BigInt.fromInt(0))

  setAccountToken(accountToken)

  accountToken
}

Handlers.ERC20Contract.Approval.handler(({event, context}) => {
  let ownerAccount = context.account.get(event.params.owner->Ethers.ethAddressToString)

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
})

Handlers.ERC20Contract.Transfer.loader(({event, context}) => {
  let fromAccount_id = event.params.from->Ethers.ethAddressToString
  let toAccount_id = event.params.to->Ethers.ethAddressToString
  let tokenAddress = event.srcAddress->Ethers.ethAddressToString
  let fromAccountToken_id = makeAccountTokenId(~tokenAddress, ~account_id=fromAccount_id)
  let toAccountToken_id = makeAccountTokenId(~tokenAddress, ~account_id=toAccount_id)
  context.accountToken.load(fromAccountToken_id, ~loaders={})
  context.accountToken.load(toAccountToken_id, ~loaders={})
})

let manipulateAccountTokenBalance = (fn, accountToken, amount) => {
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

// let subFromBalance =
Handlers.ERC20Contract.Transfer.handler(({event, context}) => {
  let {params: {from, to, value}, srcAddress} = event
  let fromAccount_id = from->Ethers.ethAddressToString
  let toAccount_id = to->Ethers.ethAddressToString
  let tokenAddress = srcAddress->Ethers.ethAddressToString
  let fromAccountToken_id = makeAccountTokenId(~tokenAddress, ~account_id=fromAccount_id)
  let toAccountToken_id = makeAccountTokenId(~tokenAddress, ~account_id=toAccount_id)

  let manipulateAccountBalance = manipulateAccountBalance(
    ~value,
    ~tokenAddress,
    ~setAccountToken=context.accountToken.set,
    ~setAccount=context.account.set,
  )

  let senderAccountToken = context.accountToken.get(fromAccountToken_id)
  let receiverAccountToken = context.accountToken.get(toAccountToken_id)
  senderAccountToken->manipulateAccountBalance(subFromBalance, ~account_id=fromAccount_id)
  receiverAccountToken->manipulateAccountBalance(addToBalance, ~account_id=toAccount_id)
})
