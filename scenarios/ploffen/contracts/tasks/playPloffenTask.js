task("play-ploffen", "Plays a new game of ploffen")
  .addParam(
    "userIndex", // this is --user-index whe running via command line
    "user index to play ploffen",
    undefined,
    types.int
  )
  .setAction(async ({ userIndex }) => {
    const accounts = await ethers.getSigners();
    const user = accounts[userIndex];
    const provider = ethers.provider;

    const Ploffen = await deployments.get("Ploffen");
    const ploffen = await ethers.getContractAt("Ploffen", Ploffen.address);

    const GameToken = await deployments.get("GameToken");
    const gameToken = await ethers.getContractAt(
      "GameToken",
      GameToken.address
    );

    const playAmount = ethers.parseEther("1");
    await mintAndApprove([user], playAmount, gameToken, ploffen);
    await ploffen.connect(user).playPloffen(playAmount);
    await increaseTime(provider, 1800);
    console.log("Someone just played Ploffen! It was: ", user.address);
  });

async function mintAndApprove(users, mintAmount, gameToken, ploffen) {
  for (const user of users) {
    await gameToken.connect(user).mint(user.address, mintAmount);
    await gameToken.connect(user).approve(ploffen.address, mintAmount);
  }
}

async function increaseTime(provider, seconds) {
  await provider.send("evm_increaseTime", [seconds]);
  await provider.send("evm_mine");
}
