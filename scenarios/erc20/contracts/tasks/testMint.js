task("mint", "Mint some erc20 tokens")
  .addParam(
    "userFromIndex", // this is --user-from-index when running via command line
    "user to send the transfer",
    undefined,
    types.int
  )
  .addParam(
    "amount", // this is --amount when running via command line
    "amount to be minted",
    undefined,
    types.int
  )
  .setAction(async ({ userFromIndex, amount }) => {
    const accounts = await ethers.getSigners();
    const provider = ethers.provider;
    const userFrom = accounts[userFromIndex % accounts.length];
    if (userFromIndex >= accounts.length) {
      console.warn(
        `There are only ${
          accounts.length
        } accounts in the network, you are actually using account index ${
          userFromIndex % accounts.length
        }`
      );
    }

    await increaseTime(provider, 1800);

    console.log(`Using account ${userFrom.address} to create new transfer.`);

    const ERC20 = await deployments.get("ERC20");
    console.log("ERC20 deployment retrieved.");

    const erc20 = await ethers.getContractAt("ERC20", ERC20.address);

    const newMintTx = await erc20
      .connect(userFrom)
      .mint(userFrom.address, amount);
    console.log("New mint made.");

    await newMintTx.wait();

  });

async function increaseTime(provider, seconds) {
  await provider.send("evm_increaseTime", [seconds]);
  await provider.send("evm_mine");
}
