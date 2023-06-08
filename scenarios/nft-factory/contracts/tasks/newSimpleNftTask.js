task("new-simple-nft", "Create new simple nft collection")
  .addParam("name", "collection name", undefined, types.string)
  .addParam("symbol", "collection symbol", undefined, types.string)
  .addParam("supply", "max supply", undefined, types.int)
  .setAction(async ({ name, symbol, supply }) => {
    const accounts = await ethers.getSigners();
    const deployer = accounts[0];

    const NftFactory = await deployments.get("NftFactory");

    const nftFactory = await ethers.getContractAt(
      "NftFactory",
      NftFactory.address
    );

    console.log(NftFactory.address)

    await nftFactory.createNft(name, symbol, supply);
  });
