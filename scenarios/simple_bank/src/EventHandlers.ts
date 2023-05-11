import {
  SimpleBankContract_registerAccountCreatedLoadEntities,
  SimpleBankContract_registerAccountCreatedHandler,
  SimpleBankContract_registerDepositMadeLoadEntities,
  SimpleBankContract_registerDepositMadeHandler,
  SimpleBankContract_registerWithdrawalMadeLoadEntities,
  SimpleBankContract_registerWithdrawalMadeHandler,
  SimpleBankContract_registerTotalBalanceChangedLoadEntities,
  SimpleBankContract_registerTotalBalanceChangedHandler
} from "../generated/src/Handlers.gen";

import { bankEntity, treasuryEntity, accountEntity } from "../generated/src/Types.gen";

SimpleBankContract_registerAccountCreatedLoadEntities(({ event, context }) => {
});

SimpleBankContract_registerAccountCreatedHandler(({ event, context }) => {
  let {userAddress} = event.params;
  let account: accountEntity = {
    id: userAddress.toString(),
    address: userAddress.toString(),
    balance: 0,
    depositCount: 0,
    withdrawalCount: 0
  };
  context.account.insert(account);
});

SimpleBankContract_registerDepositMadeLoadEntities(({ event, context }) => {
  context.account.accountBalanceChangesLoad(event.params.userAddress.toString());
 });

SimpleBankContract_registerDepositMadeHandler(({ event, context }) => {
  let {userAddress, amount} = event.params;

  let previousAccountBalance = context.account.accountBalanceChanges()?.balance ?? 0;
  let nextAccountBalance = previousAccountBalance + Number(amount);
  
  let previousAccountDepositCount = context.account.accountBalanceChanges()?.depositCount ?? 0;
  let nextAccountDepositCount = previousAccountDepositCount + 1;

  let previousAccountWithdrawalCount = context.account.accountBalanceChanges()?.withdrawalCount ?? 0;

  let account: accountEntity = {
    id: userAddress.toString(),
    address: userAddress.toString(),
    balance: nextAccountBalance,
    depositCount: nextAccountDepositCount,
    withdrawalCount: previousAccountWithdrawalCount,
  };

  context.account.update(account);
});
