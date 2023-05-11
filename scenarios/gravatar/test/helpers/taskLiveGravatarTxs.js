const hre = require("hardhat");

module.exports.default = liveGravatarTxs = async (gravatar) => {
  await hre.run("compile");
  let accounts = await hre.ethers.getSigners();

  console.log("live gravatar task");

  console.log(gravatar);

  const user2 = accounts[2];

  const newGravatarTx = await gravatar
    .connect(user2)
    .createGravatar("Live Subscribing Gravatar", "https://welldoitlive.com");

  const updateGravatarNameTx = await gravatar
    .connect(user2)
    .updateGravatarName("First Update Gravatar");

  // Wait for all transactions to complete.
  await newGravatarTx.wait();
  await updateGravatarNameTx.wait();
};
