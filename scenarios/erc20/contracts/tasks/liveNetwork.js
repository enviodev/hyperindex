task("mint-live", "Mint some erc20 tokens")
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
        `There are only ${accounts.length
        } accounts in the network, you are actually using account index ${userFromIndex % accounts.length
        }`
      );
    }

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

task("approve-live", "Approve an amount for a user")
  .addParam(
    "userFromIndex", // this is --user-from-index when running via command line
    "owner of tokens to be approved",
    undefined,
    types.int
  )
  .addParam(
    "amount", // this is --amount when running via command line
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
        `There are only ${accounts.length
        } accounts in the network, you are actually using account index ${userFromIndex % accounts.length
        }`
      );
    }

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

task("transfer-live", "Create new account")
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
        `There are only ${accounts.length
        } accounts in the network, you are actually using account index ${userFromIndex % accounts.length
        }`
      );
    }

    const userTo = accounts[userToIndex % accounts.length];
    if (userToIndex >= accounts.length) {
      console.warn(
        `There are only ${accounts.length
        } accounts in the network, you are actually using account index ${userFromIndex % accounts.length
        }`
      );
    }

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
