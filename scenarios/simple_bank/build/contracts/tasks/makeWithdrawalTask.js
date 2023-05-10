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
task("update-gravatar-name", "Update existing gravatar name")
    .addParam("name", "gravatar display name", undefined, types.string)
    .addParam("userIndex", // this is --user-index whe running via command line
"user updating existing gravatar from accounts", undefined, types.int)
    .setAction(({ name, userIndex }) => __awaiter(void 0, void 0, void 0, function* () {
    const accounts = yield ethers.getSigners();
    const user = accounts[userIndex % accounts.length];
    if (userIndex >= accounts.length) {
        console.warn(`There are only ${accounts.length} accounts in the network, you are actually using account index ${userIndex % accounts.length}`);
    }
    console.log(`Using account ${user.address} to update the name of your gravatar.`);
    const Gravatar = yield deployments.get("GravatarRegistry");
    const gravatar = yield ethers.getContractAt("GravatarRegistry", Gravatar.address);
    const usersCurrentGravatarId = yield gravatar.ownerToGravatar(user.address);
    const userDoesntHaveGravatar = (usersCurrentGravatarId == 0);
    if (userDoesntHaveGravatar) {
        console.log(`You need to create a gravatar firt before you can update it.`);
        return;
    }
    const updateGravatarNameTx = yield gravatar
        .connect(user)
        .updateGravatarName(name);
    yield updateGravatarNameTx.wait();
    let gravatarCheck = yield gravatar.getGravatar(user.address);
    console.log("Gravatar name updated", gravatarCheck);
}));
