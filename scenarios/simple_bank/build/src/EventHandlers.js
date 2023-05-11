"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const Handlers_gen_1 = require("../generated/src/Handlers.gen");
(0, Handlers_gen_1.SimpleBankContract_registerAccountCreatedLoadEntities)(({ event, context }) => {
});
(0, Handlers_gen_1.SimpleBankContract_registerAccountCreatedHandler)(({ event, context }) => {
    let { userAddress } = event.params;
    let account = {
        id: userAddress.toString(),
        address: userAddress.toString(),
        balance: 0,
        depositCount: 0,
        withdrawalCount: 0
    };
    context.account.insert(account);
});
(0, Handlers_gen_1.SimpleBankContract_registerDepositMadeLoadEntities)(({ event, context }) => {
    context.account.accountBalanceChangesLoad(event.params.userAddress.toString());
});
(0, Handlers_gen_1.SimpleBankContract_registerDepositMadeHandler)(({ event, context }) => {
    var _a, _b, _c, _d, _e, _f;
    let { userAddress, amount } = event.params;
    let previousAccountBalance = (_b = (_a = context.account.accountBalanceChanges()) === null || _a === void 0 ? void 0 : _a.balance) !== null && _b !== void 0 ? _b : 0;
    let nextAccountBalance = Number(previousAccountBalance) + Number(amount);
    let previousAccountDepositCount = (_d = (_c = context.account.accountBalanceChanges()) === null || _c === void 0 ? void 0 : _c.depositCount) !== null && _d !== void 0 ? _d : 0;
    let nextAccountDepositCount = previousAccountDepositCount + 1;
    let previousAccountWithdrawalCount = (_f = (_e = context.account.accountBalanceChanges()) === null || _e === void 0 ? void 0 : _e.withdrawalCount) !== null && _f !== void 0 ? _f : 0;
    let account = {
        id: userAddress.toString(),
        address: userAddress.toString(),
        balance: nextAccountBalance,
        depositCount: nextAccountDepositCount,
        withdrawalCount: previousAccountWithdrawalCount,
    };
    context.account.update(account);
});
(0, Handlers_gen_1.SimpleBankContract_registerWithdrawalMadeLoadEntities)(({ event, context }) => {
    context.account.accountBalanceChangesLoad(event.params.userAddress.toString());
});
(0, Handlers_gen_1.SimpleBankContract_registerWithdrawalMadeHandler)(({ event, context }) => {
    var _a, _b, _c, _d, _e, _f;
    let { userAddress, amount } = event.params;
    let previousAccountBalance = (_b = (_a = context.account.accountBalanceChanges()) === null || _a === void 0 ? void 0 : _a.balance) !== null && _b !== void 0 ? _b : 0;
    let nextAccountBalance = Number(previousAccountBalance) - Number(amount);
    let previousAccountDepositCount = (_d = (_c = context.account.accountBalanceChanges()) === null || _c === void 0 ? void 0 : _c.depositCount) !== null && _d !== void 0 ? _d : 0;
    let previousAccountWithdrawalCount = (_f = (_e = context.account.accountBalanceChanges()) === null || _e === void 0 ? void 0 : _e.withdrawalCount) !== null && _f !== void 0 ? _f : 0;
    let nextAccountWithdrawalCount = previousAccountWithdrawalCount + 1;
    let account = {
        id: userAddress.toString(),
        address: userAddress.toString(),
        balance: nextAccountBalance,
        depositCount: previousAccountDepositCount,
        withdrawalCount: nextAccountWithdrawalCount,
    };
    context.account.update(account);
});
(0, Handlers_gen_1.SimpleBankContract_registerTotalBalanceChangedLoadEntities)(({ event, context }) => {
});
(0, Handlers_gen_1.SimpleBankContract_registerTotalBalanceChangedHandler)(({ event, context }) => {
    var _a, _b;
    let { totalBalance } = event.params;
    let bankId = (_b = (_a = context.bank.totalBalanceChanges()) === null || _a === void 0 ? void 0 : _a.id) !== null && _b !== void 0 ? _b : 0;
    let bank = {
        id: String(bankId),
        totalBalance: Number(totalBalance)
    };
    context.bank.update(bank);
});
