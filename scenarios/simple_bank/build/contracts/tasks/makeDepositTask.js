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
task("make-deposit", "Making a deposit")
    .addParam("amount", "deposit amount", undefined, types.int)
    .addParam("userIndex", // this is --user-index whe running via command line
"user to create new account from accounts", undefined, types.int)
    .setAction(({ amount, userIndex }) => __awaiter(void 0, void 0, void 0, function* () {
    const accounts = yield ethers.getSigners();
    const user = accounts[userIndex % accounts.length];
    if (userIndex >= accounts.length) {
        console.warn(`There are only ${accounts.length} accounts in the network, you are actually using account index ${userIndex % accounts.length}`);
    }
    console.log(`Using account ${user.address} to make a deposit.`);
    const SimpleBank = yield deployments.get("SimpleBank");
    console.log("SimpleBank deployment retrieved.");
    const simpleBank = yield ethers.getContractAt("SimpleBank", SimpleBank.address);
    // const usersCurrentGravatarId = await gravatar.ownerToGravatar(user.address)
    // const userDoesntHaveGravatar = (usersCurrentGravatarId == 0);
    // if (userDoesntHaveGravatar) {
    //   console.log(`You need to create a gravatar firt before you can update it.`);
    //   return;
    // }
    const newDeposit1Tx = yield simpleBank
        .connect(user)
        .deposit(user.address, amount);
    yield newDeposit1Tx.wait();
    let accountCheck = yield simpleBank.getBalance(user.address);
    console.log("account created", accountCheck);
}));
