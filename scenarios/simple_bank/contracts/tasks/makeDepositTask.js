task("make-deposit", "Making a deposit")
  .addParam("amount", "deposit amount", undefined, types.int)
  .addParam(
    "userIndex", // this is --user-index whe running via command line
    "user to create new account from accounts",
    undefined,
    types.int
  )
  .setAction(async ({ amount, userIndex }) => {
    const accounts = await ethers.getSigners();
    const provider = ethers.provider;
    const user = accounts[userIndex % accounts.length];
    if (userIndex >= accounts.length) {
      console.warn(
        `There are only ${
          accounts.length
        } accounts in the network, you are actually using account index ${
          userIndex % accounts.length
        }`
      );
    }

    await increaseTime(provider, 1800);

    console.log(`Using account ${user.address} to make a deposit.`);

    const SimpleBank = await deployments.get("SimpleBank");
    console.log("SimpleBank deployment retrieved.");

    const simpleBank = await ethers.getContractAt(
      "SimpleBank",
      SimpleBank.address
    );

    const newDeposit1Tx = await simpleBank
      .connect(user)
      .deposit(Number(amount));
    console.log("New deposit made.");
    await newDeposit1Tx.wait();

    let accountCheck = await simpleBank.getBalance(user.address);
    console.log("deposit made", accountCheck);

    await increaseTime(provider, 1800);
  });

async function increaseTime(provider, seconds) {
  await provider.send("evm_increaseTime", [seconds]);
  await provider.send("evm_mine");
}
