// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// You can also run a script with `npx hardhat run <script>`. If you do that, Hardhat
// will compile your contracts, add the Hardhat Runtime Environment's members to the
// global scope, and execute the script.
const hre = require("hardhat");

async function main() {
  const provider = hre.ethers.provider;
  const accounts = await ethers.getSigners();
  const user1 = accounts[2];
  const user2 = accounts[3];
  const user3 = accounts[4];

  const GameToken = await hre.ethers.getContractFactory("GameToken");
  const gameToken = await GameToken.deploy();
  await gameToken.deployed();

  console.log(`GameToken deployed to ${gameToken.address}`);

  const Ploffen = await hre.ethers.getContractFactory("Ploffen");
  const ploffen = await Ploffen.deploy(gameToken.address);
  await ploffen.deployed();

  console.log(`Ploffen deployed to ${ploffen.address}`);

  // Going to run some test transactions to generate events :)

  await mintAndApprove([user1, user2, user3], gameToken, ploffen);

  // Start the game.
  const seedAmount = hre.ethers.utils.parseEther("10");
  await ploffen.connect(user1).startPloffen(seedAmount);

  // Play the game
  const playAmount = hre.ethers.utils.parseEther("1");
  await increaseTime(provider, 1800);
  await ploffen.connect(user2).playPloffen(playAmount);

  await increaseTime(provider, 1800);
  await ploffen.connect(user3).playPloffen(playAmount);

  await increaseTime(provider, 1800);
  await ploffen.connect(user2).playPloffen(playAmount);

  // win the game.
  await increaseTime(provider, 900000);
  await ploffen.connect(user2).winPloffen();
  // TODO: Figure out time travel to make events more real and game data more real.
}

async function increaseTime(provider, seconds) {
  await provider.send("evm_increaseTime", [seconds]);
  await provider.send("evm_mine");
}

async function mintAndApprove(users, gameToken, ploffen) {
  const mintAmount = hre.ethers.utils.parseEther("100");
  for (const user of users) {
    await gameToken.connect(user).mint(user.address, mintAmount);
    await gameToken.connect(user).approve(ploffen.address, mintAmount);
  }
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
