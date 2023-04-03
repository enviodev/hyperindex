task("update-gravatar-name", "Update existing gravatar name")
  .addParam("name", "gravatar display name", undefined, types.string)
  .addParam(
    "userIndex", // this is --user-index whe running via command line
    "user updating existing gravatar from accounts",
    undefined,
    types.int
  )
  .setAction(async ({ name, userIndex }) => {
    const accounts = await ethers.getSigners();
    const user = accounts[userIndex];

    const Gravatar = await deployments.get("GravatarRegistry");

    const gravatar = await ethers.getContractAt(
      "GravatarRegistry",
      Gravatar.address
    );

    const updateGravatarNameTx = await gravatar
      .connect(user)
      .updateGravatarName(name);
    await updateGravatarNameTx.wait();

    let gravatarCheck = await gravatar.getGravatar(user.address);
    console.log(gravatarCheck);
  });
