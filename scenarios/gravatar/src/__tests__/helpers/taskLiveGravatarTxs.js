const hre = require("hardhat");
const ethers = hre.ethers;

module.exports.default = liveGravatarTxs = async () => {
  await hre.run("compile");
  let accounts = await hre.ethers.getSigners();

  const GravatarRegistry = await hre.ethers.getContractFactory(
    "GravatarRegistry"
  );
  const gravatar = await GravatarRegistry.deploy();

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
