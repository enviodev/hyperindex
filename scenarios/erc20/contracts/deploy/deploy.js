const { network, ethers } = require("hardhat");

let networkToUse = network.name;

module.exports = async ({ getNamedAccounts, deployments }) => {
  const provider = ethers.provider;
  const { deploy } = deployments;
  const accounts = await ethers.getSigners();
  const deployer = accounts[0];
  const user1 = accounts[1];
  const user2 = accounts[2];
  const user3 = accounts[3];
  const user4 = accounts[4];

  console.log("deployer");
  console.log(deployer.address);

  console.log("user1");
  console.log(user1.address);
  
  const interestRate = 0;
  console.log("interest Rate set");

  let SimpleBankContract = await deploy("ERC20", {
    args: [interestRate],
    from: deployer.address,
    log: false,
  });

  console.log(" SimpleBank deployed to: ", SimpleBankContract.address);

  console.log("");
  console.log("Contract verification command");
  console.log("----------------------------------");
  console.log(
    `npx hardhat verify --network ${networkToUse} --contract contracts/SimpleBank.sol:SimpleBank ${SimpleBankContract.address}  `
  );
  console.log("");
}

module.exports.tags = ["deploy"];