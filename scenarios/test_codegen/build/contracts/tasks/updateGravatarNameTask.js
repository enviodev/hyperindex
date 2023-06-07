"use strict";
task("update-gravatar-name", "Update existing gravatar name")
    .addParam("name", "gravatar display name", undefined, types.string)
    .addParam("userIndex", // this is --user-index whe running via command line
"user updating existing gravatar from accounts", undefined, types.int)
    .setAction(async ({ name, userIndex }) => {
    const accounts = await ethers.getSigners();
    const user = accounts[userIndex % accounts.length];
    if (userIndex >= accounts.length) {
        console.warn(`There are only ${accounts.length} accounts in the network, you are actually using account index ${userIndex % accounts.length}`);
    }
    console.log(`Using account ${user.address} to update the name of your gravatar.`);
    const Gravatar = await deployments.get("GravatarRegistry");
    const gravatar = await ethers.getContractAt("GravatarRegistry", Gravatar.address);
    const usersCurrentGravatarId = await gravatar.ownerToGravatar(user.address);
    const userDoesntHaveGravatar = (usersCurrentGravatarId == 0);
    if (userDoesntHaveGravatar) {
        console.log(`You need to create a gravatar firt before you can update it.`);
        return;
    }
    const updateGravatarNameTx = await gravatar
        .connect(user)
        .updateGravatarName(name);
    await updateGravatarNameTx.wait();
    let gravatarCheck = await gravatar.getGravatar(user.address);
    console.log("Gravatar name updated", gravatarCheck);
});
