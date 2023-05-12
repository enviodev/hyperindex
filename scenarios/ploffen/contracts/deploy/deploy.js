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

  let GameTokenContract = await deploy("GameToken", {
    from: deployer.address,
    log: false,
  });

  console.log(`GameToken deployed to ${GameTokenContract.address}`);

  let PloffenContract = await deploy("Ploffen", {
    args: [GameTokenContract.address],
    from: deployer.address,
    log: false,
  });

  console.log(" Ploffen deployed to: ", PloffenContract.address);

  const ploffen = await ethers.getContractAt(
    "Ploffen",
    PloffenContract.address
  );
  const gameToken = await ethers.getContractAt(
    "GameToken",
    GameTokenContract.address
  );

  // Going to run some test transactions to generate events :)
  await mintAndApprove([user1, user2, user3, user4], gameToken, ploffen);

  // Start the game.
  const seedAmount = ethers.parseEther("10");
  await ploffen.connect(user1).startPloffen(seedAmount);

  // Play the game
  const playAmount = hre.ethers.parseEther("1");
  await increaseTime(provider, 1800);
  await ploffen.connect(user2).playPloffen(playAmount);
  console.log("Someone just played Ploffen! It was: ", user2.address);

  await increaseTime(provider, 1800);
  await ploffen.connect(user3).playPloffen(playAmount);
  console.log("Someone just played Ploffen! It was: ", user3.address);

  await increaseTime(provider, 1800);
  await ploffen.connect(user2).playPloffen(playAmount);
  console.log("Someone just played Ploffen! It was: ", user2.address);
};

async function increaseTime(provider, seconds) {
  await provider.send("evm_increaseTime", [seconds]);
  await provider.send("evm_mine");
}

async function mintAndApprove(users, gameToken, ploffen) {
  const mintAmount = ethers.parseEther("100");
  for (const user of users) {
    await gameToken.connect(user).mint(user.address, mintAmount);
    await gameToken.connect(user).approve(ploffen.target, mintAmount);
  }
}

module.exports.tags = ["deploy"];
