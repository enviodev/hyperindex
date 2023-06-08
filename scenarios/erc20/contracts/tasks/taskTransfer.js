task("transfer", "Create new account")
  .addParam(
    "userFromIndex", // this is --user-from-index whe running via command line
    "user to send the transfer",
    undefined,
    types.int
  )
  .addParam(
    "userToIndex", // this is --user-to-index when running via command line
    "user to receive the transfer",
    undefined,
    types.int
  )
  .addParam(
    "amount", // this is --amount when running via command line
    "amount to be transferred",
    undefined,
    types.int
  )
  .setAction(async ({ userFromIndex, userToIndex, amount }) => {
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

    const userTo = accounts[userToIndex % accounts.length];
    if (userToIndex >= accounts.length) {
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

    const newTransferTx = await erc20
      .connect(userFrom)
      .transfer(userTo.address, amount);
    console.log("New transfer made to user: ", userTo.address);

    await newTransferTx.wait();

    console.log(userFrom);
    console.log(userFrom.address);

    await increaseTime(provider, 1800);
  });

async function increaseTime(provider, seconds) {
  await provider.send("evm_increaseTime", [seconds]);
  await provider.send("evm_mine");
}
