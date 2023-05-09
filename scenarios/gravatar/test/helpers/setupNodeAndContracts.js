const hre = require("hardhat");
const ethers = hre.ethers;

module.exports.deployContract = deployContract = async () => {
  await hre.run("compile");
  let accounts = await hre.ethers.getSigners();

  const GravatarRegistry = await hre.ethers.getContractFactory("GravatarRegistry");
  const gravatar = await GravatarRegistry.deploy();
  return gravatar
}

module.exports.default = setupNodeAndContracts = async (gravatar) => {
  await hre.run("compile");
  let accounts = await hre.ethers.getSigners();

  const deployer = accounts[0];
  const user1 = accounts[1];

  console.log("using account, ", user1)

  const newGravatar1Tx = await gravatar.createGravatar(
    "First Gravatar",
    "https://something.com"
  );

  console.log("gravatar address", gravatar)

  const newGravatar2Tx = await gravatar
    .connect(user1)
    .createGravatar("Second Gravatar", "https://something2.com");

  const updateGravatarName1Tx = await gravatar.updateGravatarName(
    "First Update Gravatar"
  );

  console.log("update gravatar")
  const updateGravatarUrl1Tx = await gravatar.updateGravatarImage(
    "https://something1Update.com"
  );

  // Wait for all transactions to complete.
  await newGravatar1Tx.wait();
  await newGravatar2Tx.wait();
  await updateGravatarName1Tx.wait();
  await updateGravatarUrl1Tx.wait();
};
