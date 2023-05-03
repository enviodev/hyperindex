task("win-ploffen", "Tries to win game of ploffen")
  .addParam(
    "userIndex", // this is --user-index whe running via command line
    "user index to try win ploffen",
    undefined,
    types.int
  )
  .setAction(async ({ userIndex }) => {
    const accounts = await ethers.getSigners();
    const user = accounts[userIndex];
    const provider = ethers.provider;

    const Ploffen = await deployments.get("Ploffen");
    const ploffen = await ethers.getContractAt("Ploffen", Ploffen.address);

    await increaseTime(provider, 1800);
    await ploffen.connect(user).winPloffen();
    console.log("Someone just won Ploffen! It was: ", user.address);
  });

async function increaseTime(provider, seconds) {
  await provider.send("evm_increaseTime", [seconds]);
  await provider.send("evm_mine");
}
