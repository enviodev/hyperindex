import {
  SimpleBankContract_registerAccountCreatedLoadEntities,
  SimpleBankContract_registerAccountCreatedHandler,
  SimpleBankContract_registerDepositMadeLoadEntities,
  SimpleBankContract_registerDepositMadeHandler,
  SimpleBankContract_registerWithdrawalMadeLoadEntities,
  SimpleBankContract_registerWithdrawalMadeHandler,
} from "../generated/src/Handlers.gen";

import { bankEntity, accountEntity } from "../generated/src/Types.gen";

SimpleBankContract_registerAccountCreatedLoadEntities(
  ({ event, context }) => { }
);

SimpleBankContract_registerAccountCreatedHandler(({ event, context }) => {
  let { userAddress } = event.params;
  let account: accountEntity = {
    id: userAddress.toString(),
    address: userAddress.toString(),
    balance: 0,
    depositCount: 0,
    withdrawalCount: 0,
  };
  context.account.set(account);
});

SimpleBankContract_registerDepositMadeLoadEntities(({ event, context }) => {
  context.account.accountBalanceChangesLoad(
    event.params.userAddress.toString()
  );
  context.bank.totalBalanceChangesLoad(event.srcAddress.toString());
});

SimpleBankContract_registerDepositMadeHandler(({ event, context }) => {
  let { userAddress, amount } = event.params;

  let previousAccountBalance =
    context.account.accountBalanceChanges()?.balance ?? 0;
  let nextAccountBalance = Number(previousAccountBalance) + Number(amount);

  let previousAccountDepositCount =
    context.account.accountBalanceChanges()?.depositCount ?? 0;
  let nextAccountDepositCount = previousAccountDepositCount + 1;

  let previousAccountWithdrawalCount =
    context.account.accountBalanceChanges()?.withdrawalCount ?? 0;

  let account: accountEntity = {
    id: userAddress.toString(),
    address: userAddress.toString(),
    balance: nextAccountBalance,
    depositCount: nextAccountDepositCount,
    withdrawalCount: previousAccountWithdrawalCount,
  };

  let perviousBankBalance =
    context.bank.totalBalanceChanges()?.totalBalance ?? 0;
  let nextBankBalance = Number(perviousBankBalance) + Number(amount);

  let bank: bankEntity = {
    id: event.srcAddress.toString(),
    totalBalance: nextBankBalance,
  };

  context.account.update(account);
  context.bank.update(bank);
});

SimpleBankContract_registerWithdrawalMadeLoadEntities(({ event, context }) => {
  context.account.accountBalanceChangesLoad(
    event.params.userAddress.toString()
  );
  context.bank.totalBalanceChangesLoad(event.srcAddress.toString());
});

SimpleBankContract_registerWithdrawalMadeHandler(({ event, context }) => {
  let { userAddress, amount } = event.params;

  let previousAccountBalance =
    context.account.accountBalanceChanges()?.balance ?? 0;
  let nextAccountBalance = Number(previousAccountBalance) - Number(amount);

  let previousAccountDepositCount =
    context.account.accountBalanceChanges()?.depositCount ?? 0;

  let previousAccountWithdrawalCount =
    context.account.accountBalanceChanges()?.withdrawalCount ?? 0;
  let nextAccountWithdrawalCount = previousAccountWithdrawalCount + 1;

  let account: accountEntity = {
    id: userAddress.toString(),
    address: userAddress.toString(),
    balance: nextAccountBalance,
    depositCount: previousAccountDepositCount,
    withdrawalCount: nextAccountWithdrawalCount,
  };

  let perviousBankBalance =
    context.bank.totalBalanceChanges()?.totalBalance ?? 0;
  let nextBankBalance = Number(perviousBankBalance) - Number(amount);

  let bank: bankEntity = {
    id: event.srcAddress.toString(),
    totalBalance: nextBankBalance,
  };

  context.account.update(account);
  context.bank.update(bank);
});
