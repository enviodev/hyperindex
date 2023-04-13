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
    const user = accounts[userIndex];

    const Gravatar = await deployments.get("GravatarRegistry");

    const gravatar = await ethers.getContractAt(
      "GravatarRegistry",
      Gravatar.address
    );
    const newGravatar1Tx = await gravatar
      .connect(user)
      .createGravatar(name, image);

    await newGravatar1Tx.wait();

    let gravatarCheck = await gravatar.getGravatar(user.address);
    console.log(gravatarCheck);
  });
