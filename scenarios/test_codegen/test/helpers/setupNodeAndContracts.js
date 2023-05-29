const hre = require("hardhat");

let deployedContracts = undefined
module.exports.deployContracts = async () => {
  // Stops the deployment if the contracts are already deployed
  if (!!deployedContracts) {
    return deployedContracts
  }

  deployedContracts = {}

  await hre.run("compile");

  let accounts = await hre.ethers.getSigners();
  let deployer = accounts[0]

  const GravatarRegistry = (await hre.ethers.getContractFactory(
    "GravatarRegistry"
  )).connect(deployer);
  deployedContracts.gravatar = await GravatarRegistry.deploy();

  let NftFactory = (await hre.ethers.getContractFactory(
    "NftFactory",
  )).connect(deployer);
  deployedContracts.nftFactory = await NftFactory.deploy();

  console.log("deployed contracts", deployedContracts.nftFactory.target)
  console.log("deployed contracts", deployedContracts.gravatar.target)

  return deployedContracts;
};

const setupNodeAndContracts = async (gravatar) => {
  await hre.run("compile");
  let accounts = await hre.ethers.getSigners();

  const deployer = accounts[0];
  const user1 = accounts[1];

  console.log("using account, ", user1);

  const newGravatar1Tx = await gravatar.createGravatar(
    "First Gravatar",
    "https://something.com"
  );

  console.log("gravatar address", gravatar);

  const newGravatar2Tx = await gravatar
    .connect(user1)
    .createGravatar("Second Gravatar", "https://something2.com");

  const updateGravatarName1Tx = await gravatar.updateGravatarName(
    "First Update Gravatar"
  );

  console.log("update gravatar");
  const updateGravatarUrl1Tx = await gravatar.updateGravatarImage(
    "https://something1Update.com"
  );

  // Wait for all transactions to complete.
  await newGravatar1Tx.wait();
  await newGravatar2Tx.wait();
  await updateGravatarName1Tx.wait();
  await updateGravatarUrl1Tx.wait();
};

module.exports.default = setupNodeAndContracts
