const { network } = require("hardhat");

let networkToUse = network.name;

module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deploy } = deployments;
  const accounts = await ethers.getSigners();
  const deployer = accounts[0];
  const user1 = accounts[1];

  console.log("deployer");
  console.log(deployer.address);

  let NFtFactory = await deploy("NftFactory", {
    from: deployer.address,
    log: true,
  });

  console.log(" Nft Factory deployed to: ", NFtFactory.address);

  const nftFactory = await ethers.getContractAt(
    "NftFactory",
    NFtFactory.address
  );
  const newSimpleNft1Tx = await nftFactory.createNft(
    "First Simple NFT",
    "FSNFT",
    100
  );
  await newSimpleNft1Tx.wait();
};

module.exports.tags = ["deploy"];
