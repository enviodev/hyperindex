import "@nomiclabs/hardhat-ethers";
import { HardhatUserConfig } from "hardhat/config";

import "@typechain/hardhat";
import { TypechainUserConfig } from "@typechain/hardhat/dist/types";

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
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 1337,
      accounts: {
        mnemonic: "test test test test test test test test test test test junk",
      },
    },
  },
};

export default config;
