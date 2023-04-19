task("new-gravatar", "Create new gravatar")
  .addParam("name", "gravatar display name", undefined, types.string)
  .addParam("image", "gravatar image url", undefined, types.string)
  .addParam(
    "userIndex", // this is --user-index whe running via command line
    "user to create new gravatar from accounts",
    undefined,
    types.int
  )
  .setAction(async ({ name, image, userIndex }) => {
    const accounts = await ethers.getSigners();
    const user = accounts[userIndex % accounts.length];
    if (userIndex >= accounts.length) {
      console.warn(`There are only ${accounts.length} accounts in the network, you are actually using account index ${userIndex % accounts.length}`);
    }

    console.log(`Using account ${user.address} to create new gravatar.`);

    const Gravatar = await deployments.get("GravatarRegistry");

    const gravatar = await ethers.getContractAt(
      "GravatarRegistry",
      Gravatar.address
    );

    const usersCurrentGravatarId = await gravatar.ownerToGravatar(user.address)
    const alreadyHasAGravatar = (usersCurrentGravatarId != 0);
    if (alreadyHasAGravatar) {
      console.log(`User's already has a gravatar, you can update it, your gravatar has id ${usersCurrentGravatarId}.`);
      return;
    }

    const newGravatar1Tx = await gravatar
      .connect(user)
      .createGravatar(name, image);

    await newGravatar1Tx.wait();

    let gravatarCheck = await gravatar.getGravatar(user.address);
    console.log("gravatar created", gravatarCheck);
  });
