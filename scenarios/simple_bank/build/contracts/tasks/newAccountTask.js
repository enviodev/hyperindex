"use strict";
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
task("new-account", "Create new account")
    .addParam("address", "user address", undefined, types.string)
    .addParam("userIndex", // this is --user-index whe running via command line
"user to create new account from accounts", undefined, types.int)
    .setAction(({ address, userIndex }) => __awaiter(void 0, void 0, void 0, function* () {
    const accounts = yield ethers.getSigners();
    const user = accounts[userIndex % accounts.length];
    if (userIndex >= accounts.length) {
        console.warn(`There are only ${accounts.length} accounts in the network, you are actually using account index ${userIndex % accounts.length}`);
    }
    console.log(`Using account ${user.address} to create new account.`);
    const SimpleBank = yield deployments.get("SimpleBank");
    const simpleBank = yield ethers.getContractAt("SimpleBank", SimpleBank.address);
    // perform this check?
    const usersCurrentAccountBalance = yield simpleBank.balances(user.address);
    const alreadyHasAnAccount = (usersCurrentAccountBalance != 0);
    if (alreadyHasAnAccount) {
        console.log(`User's current account balance is ${usersCurrentAccountBalance}, so they already have an account.`);
        return;
    }
    const newAccount1 = yield simpleBank
        .connect(user)
        .creatAccount(address);
    yield newAccount1.wait();
    let accountCheck = yield simpleBank.getBalance(user.address);
    console.log("account created", accountCheck);
}));
