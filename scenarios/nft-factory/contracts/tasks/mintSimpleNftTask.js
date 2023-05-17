task("mint-nft", "mint super nfts")
  .addParam("address", "address of nft contract", undefined, types.string)
  .addParam("quantity", "quantity to mint", undefined, types.int)
  .addParam(
    "userIndex",
    "user updating existing gravatar from accounts",
    undefined,
    types.int
  )
  .setAction(async ({ address, quantity, userIndex }) => {
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

    console.log(`Using account ${user.address} to mint NFT.`);

    let contractAddress = ethers.getAddress(address);

    const SimpleNft = await ethers.getContractAt("SimpleNft", contractAddress);

    const mintNftTx = await SimpleNft.connect(user).mint(quantity);

    await mintNftTx.wait();
    const totalSupply = await SimpleNft.totalSupply();
    console.log("total supply:", totalSupply);
  });
