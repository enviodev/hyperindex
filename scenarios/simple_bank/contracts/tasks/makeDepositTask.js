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

    console.log(`Using account ${user.address} to make a deposit.`);

    const SimpleBank = await deployments.get("SimpleBank");
    console.log("SimpleBank deployment retrieved.");

    const simpleBank = await ethers.getContractAt(
      "SimpleBank",
      SimpleBank.address
    );

    // const usersCurrentGravatarId = await gravatar.ownerToGravatar(user.address)
    // const userDoesntHaveGravatar = (usersCurrentGravatarId == 0);
    // if (userDoesntHaveGravatar) {
    //   console.log(`You need to create a gravatar firt before you can update it.`);
    //   return;
    // }
    const newDeposit1Tx = await simpleBank
      .connect(user)
      .deposit(user.address, amount);
    await newDeposit1Tx.wait();

    let accountCheck = await simpleBank.getBalance(user.address);
    console.log("account created", accountCheck);
  });
