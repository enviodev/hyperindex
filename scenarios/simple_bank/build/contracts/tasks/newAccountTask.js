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
    .addParam("userIndex", // this is --user-index whe running via command line
"user to create new account from accounts", undefined, types.int)
    .setAction(({ userIndex }) => __awaiter(void 0, void 0, void 0, function* () {
    const accounts = yield ethers.getSigners();
    const provider = ethers.provider;
    const user = accounts[userIndex % accounts.length];
    if (userIndex >= accounts.length) {
        console.warn(`There are only ${accounts.length} accounts in the network, you are actually using account index ${userIndex % accounts.length}`);
    }
    yield increaseTime(provider, 1800);
    console.log(`Using account ${user.address} to create new account.`);
    const SimpleBank = yield deployments.get("SimpleBank");
    console.log("SimpleBank deployment retrieved.");
    const simpleBank = yield ethers.getContractAt("SimpleBank", SimpleBank.address);
    const newAccount1Tx = yield simpleBank
        .connect(user)
        .createAccount(user.address);
    console.log("New account created.");
    yield newAccount1Tx.wait();
    console.log(user);
    console.log(user.address);
    let accountCheck = yield simpleBank.getBalance(user.address);
    console.log("account created", accountCheck);
    yield increaseTime(provider, 1800);
}));
function increaseTime(provider, seconds) {
    return __awaiter(this, void 0, void 0, function* () {
        yield provider.send("evm_increaseTime", [seconds]);
        yield provider.send("evm_mine");
    });
}
