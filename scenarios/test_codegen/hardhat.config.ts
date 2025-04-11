import "@nomiclabs/hardhat-ethers";
import "hardhat-deploy";
import { HardhatUserConfig } from "hardhat/config";

import "hardhat-abi-exporter";

import "@typechain/hardhat";
import "./contracts/tasks";
import { TypechainUserConfig } from "@typechain/hardhat/dist/types";

let secertsConfig;
try {
  secertsConfig = require("./contracts/secretsManager.ts");
} catch (e) {
  console.error(
    "You are using the example secrets manager, please copy this file if you want to use it"
  );
  secertsConfig = require("./contracts/secretsManager.example.ts");
}

const { mnemonic } = secertsConfig;
let typeChainConfig: TypechainUserConfig = {
  target: "ethers-v6",
};

const config: HardhatUserConfig = {
  solidity: "0.8.19",
  paths: {
    root: "contracts",
  },
  typechain: typeChainConfig,
  abiExporter: {
    path: "./abis",
    clear: true,
    flat: true,
    spacing: 2,
  },
  networks: {
    hardhat: {
      chainId: 1337,
      accounts: {
        mnemonic: "test test test test test test test test test test test test",
      },
    },
  },
};

export default config;
