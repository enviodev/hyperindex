import {
  SimpleBankContract_AccountCreated_loader,
  SimpleBankContract_AccountCreated_handler,
  SimpleBankContract_DepositMade_loader,
  SimpleBankContract_DepositMade_handler,
  SimpleBankContract_WithdrawalMade_loader,
  SimpleBankContract_WithdrawalMade_handler,
} from "../generated/src/Handlers.gen";

import { bankEntity, accountEntity } from "../generated/src/Types.gen";

SimpleBankContract_AccountCreated_loader(
  ({ event, context }) => { }
);

SimpleBankContract_AccountCreated_handler(({ event, context }) => {
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

SimpleBankContract_DepositMade_loader(({ event, context }) => {
  context.account.accountBalanceChangesLoad(
    event.params.userAddress.toString()
  );
  context.bank.totalBalanceChangesLoad(event.srcAddress.toString());
});

SimpleBankContract_DepositMade_handler(({ event, context }) => {
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

  context.account.set(account);
  context.bank.set(bank);
});

SimpleBankContract_WithdrawalMade_loader(({ event, context }) => {
  context.account.accountBalanceChangesLoad(
    event.params.userAddress.toString()
  );
  context.bank.totalBalanceChangesLoad(event.srcAddress.toString());
});

SimpleBankContract_WithdrawalMade_handler(({ event, context }) => {
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

  context.account.set(account);
  context.bank.set(bank);
});
