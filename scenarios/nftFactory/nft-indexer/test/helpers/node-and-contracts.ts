import hre from "hardhat";

export const deployContract = async () => {
  await hre.run("compile");

  const NftFactory = await hre.ethers.getContractFactory("NftFactory", {
    libraries: {
      open: "",
    },
  });
  const deployedNftFactory = await NftFactory.deploy();

  return deployedNftFactory;
};

type NftArgs = {
  name: string;
  symbol: string;
  supply: number;
};

export const createNft = async (
  nftFactory: any,
  nftArgs: NftArgs
): Promise<void> => {
  let { name, symbol, supply } = nftArgs;
  return await nftFactory.createNft(name, symbol, supply);
};

enum User {
  FirstUser,
  SecondUser,
  ThirdUser,
}

export const mintSimpleNft = async (
  userIndex: User,
  nftContractAddress: string,
  quantity: number
) => {
  const ethers = hre.ethers;
  const accounts = await ethers.getSigners();
  const user = accounts[userIndex];

  console.log(`Using account ${user.address} to mint NFT.`);

  let contractAddress = ethers.getAddress(nftContractAddress);

  const SimpleNft = (await ethers.getContractAt(
    "SimpleNft",
    contractAddress
  )) as any;

  const mintNftTx = await SimpleNft.connect(user).mint(quantity);

  await mintNftTx.wait();
  const totalSupply = await SimpleNft.totalSupply();
  console.log(totalSupply);
};
