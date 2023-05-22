import "@nomiclabs/hardhat-ethers";
import "hardhat-deploy";
import "hardhat-abi-exporter";
import { HardhatUserConfig } from "hardhat/config";

import "@typechain/hardhat";
import "./contracts/tasks";
import { TypechainUserConfig } from "@typechain/hardhat/dist/types";

import { mnemonic } from "./secretsManager";

let typeChainConfig: TypechainUserConfig = {
  target: "ethers-v6",
};

const config: HardhatUserConfig = {
  solidity: "0.8.19",
  paths: {
    root: "contracts",
  },
  typechain: typeChainConfig,
  networks: {
    ganache: {
      url: "http://0.0.0.0:8545",
      chainId: 1337,
    },
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 1337,
      accounts: {
        mnemonic: "test test test test test test test test test test test junk",
      },
    },
    fuji: {
      url: 'https://api.avax-test.network/ext/bc/C/rpc',
      gasPrice: 225000000000,
      chainId: 43113,
      accounts: { mnemonic },
    },
  },
  abiExporter: {
    path: "./abis",
    clear: true,
    flat: true,
    spacing: 2,
  },
};

export default config;
