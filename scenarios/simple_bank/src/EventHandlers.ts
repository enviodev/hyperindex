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

import { bankEntity, accountEntity } from "../generated/src/Types.gen";

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
   let nextAccountBalance = Number(previousAccountBalance) + Number(amount);
   
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

SimpleBankContract_registerWithdrawalMadeLoadEntities(({ event, context }) => {
  context.account.accountBalanceChangesLoad(event.params.userAddress.toString());
 });

 SimpleBankContract_registerWithdrawalMadeHandler(({ event, context }) => {
  let {userAddress, amount} = event.params;

  let previousAccountBalance = context.account.accountBalanceChanges()?.balance ?? 0;
  let nextAccountBalance = Number(previousAccountBalance) - Number(amount);
  
  let previousAccountDepositCount = context.account.accountBalanceChanges()?.depositCount ?? 0;
  
  let previousAccountWithdrawalCount = context.account.accountBalanceChanges()?.withdrawalCount ?? 0;
  let nextAccountWithdrawalCount = previousAccountWithdrawalCount + 1;

  let account: accountEntity = {
    id: userAddress.toString(),
    address: userAddress.toString(),
    balance: nextAccountBalance,
    depositCount: previousAccountDepositCount,
    withdrawalCount: nextAccountWithdrawalCount,
  };

  context.account.update(account);
});

SimpleBankContract_registerTotalBalanceChangedLoadEntities(({ event, context }) => {
 });

 SimpleBankContract_registerTotalBalanceChangedHandler(({ event, context }) => {
  let {totalBalance} = event.params;
  
  let bankId = context.bank.totalBalanceChanges()?.id ?? 0;

  let bank: bankEntity = {
    id: String(bankId),
    totalBalance: Number(totalBalance)
  };

  context.bank.update(bank);
});

