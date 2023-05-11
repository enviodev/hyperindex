task("new-account", "Create new account")
  .addParam(
    "userIndex", // this is --user-index whe running via command line
    "user to create new account from accounts",
    undefined,
    types.int
  )
  .setAction(async ({userIndex }) => {
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

    console.log(`Using account ${user.address} to create new account.`);

    const SimpleBank = await deployments.get("SimpleBank");
    console.log("SimpleBank deployment retrieved.");

    const simpleBank = await ethers.getContractAt(
      "SimpleBank",
      SimpleBank.address
    );
    console.log("SimpleBank contract address retrieved.");
    console.log("SimpleBank.address", SimpleBank.address);

    // const usersCurrentAccountBalance = await simpleBank.balances(user.address);
    // console.log("Current account balance retrieved.");
    // const alreadyHasAnAccount = usersCurrentAccountBalance != 0;
    // if (alreadyHasAnAccount) {
    //   console.log(
    //     `User's current account balance is ${usersCurrentAccountBalance}, so they already have an account.`
    //   );
    //   return;
    // }

    const newAccount1Tx = await simpleBank.connect(user).createAccount(user.address);
    console.log("New account created.");

    await newAccount1Tx.wait();
    
    console.log(user);
    console.log(user.address);
    
    let accountCheck = await simpleBank.getBalance(user.address);
    console.log("account created", accountCheck);
  });
