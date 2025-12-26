open Entities

Indexer.ERC20Factory.TokenCreated.contractRegister(async ({event, context}) => {
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

  let accountToken = makeAccountToken(~account_id, ~tokenAddress, ~balance=BigInt.fromInt(0))

  setAccountToken(accountToken)

  accountToken
}

Indexer.ERC20.Approval.handler(async ({event, context}) => {
  let ownerAccount = await context.account.get(event.params.owner->Address.toString)

  let account_id = event.params.owner->Address.toString
  let tokenAddress = event.srcAddress->Address.toString
  if ownerAccount->Belt.Option.isNone {
    createNewAccountWithZeroBalance(
      ~account_id,
      ~tokenAddress,
      ~setAccount=context.account.set,
      ~setAccountToken=context.accountToken.set,
    )->ignore
  }

  let approvalEntity = makeApprivalEntity(
    ~spender_id=event.params.spender->Address.toString,
    ~owner_id=account_id,
    ~tokenAddress,
    ~amount=event.params.value,
  )

  // this is the same for create or update as the amount is overwritten
  context.approval.set(approvalEntity)

  // context.account.load(event.params.owner->Address.toString)
})

let manipulateAccountTokenBalance = (fn, accountToken: AccountToken.t, amount): AccountToken.t => {
  {...accountToken, balance: accountToken.balance->fn(amount)}
}

let addToBalance = manipulateAccountTokenBalance(BigInt.add, ...)
let subFromBalance = manipulateAccountTokenBalance(BigInt.sub, ...)

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

Indexer.ERC20.Transfer.handler(async ({event, context}) => {
  let fromAccount_id = event.params.from->Address.toString
  let toAccount_id = event.params.to->Address.toString
  let tokenAddress = event.srcAddress->Address.toString
  let fromAccountToken_id = makeAccountTokenId(~tokenAddress, ~account_id=fromAccount_id)
  let toAccountToken_id = makeAccountTokenId(~tokenAddress, ~account_id=toAccount_id)

  let (senderAccountToken, receiverAccountToken) =
    await (
      context.accountToken.get(fromAccountToken_id),
      context.accountToken.get(toAccountToken_id),
    )->Promise.all2

  let {params: {from, to, value}, srcAddress} = event
  let fromAccount_id = from->Address.toString
  let toAccount_id = to->Address.toString
  let tokenAddress = srcAddress->Address.toString

  let manipulateAccountBalance =
    manipulateAccountBalance(
      ~value,
      ~tokenAddress,
      ~setAccountToken=context.accountToken.set,
      ~setAccount=context.account.set,
      ...
    )

  senderAccountToken->manipulateAccountBalance(subFromBalance, ~account_id=fromAccount_id)
  receiverAccountToken->manipulateAccountBalance(addToBalance, ~account_id=toAccount_id)
})

Indexer.ERC20Factory.DeleteUser.handler(async ({event, context}) => {
  let account_id = event.params.user->Address.toString
  let accountTokens = await context.accountToken.getWhere.account_id.eq(account_id)

  context.account.deleteUnsafe(event.params.user->Address.toString)
  accountTokens->Belt.Array.forEach(accountToken => {
    context.accountToken.deleteUnsafe(accountToken.id)
  })
})
