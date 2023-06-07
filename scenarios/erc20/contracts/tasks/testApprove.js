task("approve", "Approve an amount for a user")
  .addParam(
    "userFromIndex", // this is --user-index whe running via command line
    "owner of tokens to be approved",
    undefined,
    types.int
  )
  .addParam(
    "amount", // this is --user-index whe running via command line
    "amount to be approved",
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

    const newApprovalTx = await erc20
      .connect(userFrom)
      .approve(userFrom.address, amount);
    console.log("New approval made.");

    await newApprovalTx.wait();

  });

async function increaseTime(provider, seconds) {
  await provider.send("evm_increaseTime", [seconds]);
  await provider.send("evm_mine");
}
