task("update-gravatar-image", "Update existing gravatar image")
  .addParam("image", "gravatar image url", undefined, types.string)
  .addParam(
    "userIndex", // this is --user-index whe running via command line
    "user updating existing gravatar from accounts",
    undefined,
    types.int
  )
  .setAction(async ({ image, userIndex }) => {
    const accounts = await ethers.getSigners();
    const user = accounts[userIndex];

    const Gravatar = await deployments.get("GravatarRegistry");

    const gravatar = await ethers.getContractAt(
      "GravatarRegistry",
      Gravatar.address
    );

    const updateGravatarImageTx = await gravatar
      .connect(user)
      .updateGravatarImage(image);
    await updateGravatarImageTx.wait();

    let gravatarCheck = await gravatar.getGravatar(user.address);
    console.log(gravatarCheck);
  });
