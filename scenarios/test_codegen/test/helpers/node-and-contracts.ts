import hre from "hardhat";
import {
  NftFactory,
  NftFactory__factory,
  SimpleNft__factory,
} from "../../contracts/typechain-types";
import { ContractTransactionResponse } from "ethers";

export enum Users {
  Deployer,
  User1,
  User2,
  User3,
}

type NftArgs = {
  name: string;
  symbol: string;
  supply: number;
};

export const createNftFromFactory = async (
  nftFactory: NftFactory & {
    deploymentTransaction(): ContractTransactionResponse;
  },
  nftArgs: NftArgs
) => {
  let { name, symbol, supply } = nftArgs;

  return await nftFactory.createNft(name, symbol, supply);
};

export const mintSimpleNft = async (
  userIndex: Users,
  simpleNftContractAddress: string,
  quantity: number
) => {
  const ethers = hre.ethers;
  const accounts = await ethers.getSigners();
  const user = accounts[userIndex];

  console.log(`Using account ${user.address} to mint NFT.`);

  const contractAddress = ethers.getAddress(simpleNftContractAddress);
  const simpleNftContract = SimpleNft__factory.connect(contractAddress, user);
  const mintNftTx = await simpleNftContract.mint(quantity);

  await mintNftTx.wait();
  return mintNftTx;
};

export const getSimpleNftTotalSupply = async (
  simpleNftContractAddress: string
) => {
  const contractAddress = hre.ethers.getAddress(simpleNftContractAddress);
  const simpleNftContract = SimpleNft__factory.connect(contractAddress);

  return await simpleNftContract.totalSupply();
};
