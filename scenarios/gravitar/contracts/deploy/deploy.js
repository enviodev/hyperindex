const { network } = require("hardhat");

let networkToUse = network.name;

module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deploy } = deployments;
  const accounts = await ethers.getSigners();
  const deployer = accounts[0];
  const user1 = accounts[1];

  console.log("deployer");
  console.log(deployer.address);

  let GravityContract = await deploy("GravatarRegistry", {
    from: deployer.address,
    log: true,
  });

  console.log(" Gravity deployed to: ", GravityContract.address);

  console.log("");
  console.log("Contract verification command");
  console.log("----------------------------------");
  console.log(
    `npx hardhat verify --network ${networkToUse} --contract contracts/Gravity.sol:Gravity ${GravityContract.address}  `
  );
  console.log("");

  const gravatar = await ethers.getContractAt(
    "GravatarRegistry",
    GravityContract.address
  );
  const newGravatar1Tx = await gravatar.createGravatar(
    "First Gravatar",
    "https://something.com"
  );

  await newGravatar1Tx.wait();

  let gravatarCheck1 = await gravatar.getGravatar(deployer.address);
  console.log(gravatarCheck1);

  const newGravatar2Tx = await gravatar
    .connect(user1)
    .createGravatar("Second Gravatar", "https://something2.com");

  await newGravatar2Tx.wait();

  let gravatarCheck2 = await gravatar.getGravatar(user1.address);
  console.log(gravatarCheck2);

  const updateGravatarName1Tx = await gravatar.updateGravatarName(
    "First Update Gravatar"
  );

  await updateGravatarName1Tx.wait();

  let updateGravatarNameCheck1 = await gravatar.getGravatar(deployer.address);
  console.log(updateGravatarNameCheck1);

  const updateGravatarUrl1Tx = await gravatar.updateGravatarImage(
    "https://something1Update.com"
  );

  await updateGravatarUrl1Tx.wait();

  let updateGravatarurlCheck1 = await gravatar.getGravatar(deployer.address);
  console.log(updateGravatarurlCheck1);
};

module.exports.tags = ["deploy"];
